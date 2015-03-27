{- Url downloading.
 -
 - Copyright 2011-2014 Joey Hess <id@joeyh.name>
 -
 - License: BSD-2-clause
 -}

{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Utility.Url (
	URLString,
	UserAgent,
	UrlOptions,
	mkUrlOptions,
	check,
	checkBoth,
	exists,
	UrlInfo(..),
	getUrlInfo,
	download,
	downloadQuiet,
	parseURIRelaxed
) where

import Common
import Network.URI
import Network.HTTP.Conduit
import Network.HTTP.Types
import qualified Data.CaseInsensitive as CI
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as B8

import qualified Build.SysConfig

type URLString = String

type Headers = [String]

type UserAgent = String

data UrlOptions = UrlOptions
	{ userAgent :: Maybe UserAgent
	, reqHeaders :: Headers
	, reqParams :: [CommandParam]
#if MIN_VERSION_http_conduit(2,0,0)
	, applyRequest :: Request -> Request
#else
	, applyRequest :: forall m. Request m -> Request m
#endif
	}

instance Default UrlOptions
  where
	def = UrlOptions Nothing [] [] id

mkUrlOptions :: Maybe UserAgent -> Headers -> [CommandParam] -> UrlOptions
mkUrlOptions useragent reqheaders reqparams =
	UrlOptions useragent reqheaders reqparams applyrequest
  where
	applyrequest = \r -> r { requestHeaders = requestHeaders r ++ addedheaders }
	addedheaders = uaheader ++ otherheaders
	uaheader = case useragent of
		Nothing -> []
		Just ua -> [(hUserAgent, B8.fromString ua)]
	otherheaders = map toheader reqheaders
	toheader s =
		let (h, v) = separate (== ':') s
		    h' = CI.mk (B8.fromString h)
		in case v of
			(' ':v') -> (h', B8.fromString v')
			_ -> (h', B8.fromString v)

addUserAgent :: UrlOptions -> [CommandParam] -> [CommandParam]
addUserAgent uo ps = case userAgent uo of
	Nothing -> ps
	-- --user-agent works for both wget and curl commands
	Just ua -> ps ++ [Param "--user-agent", Param ua] 

{- Checks that an url exists and could be successfully downloaded,
 - also checking that its size, if available, matches a specified size. -}
checkBoth :: URLString -> Maybe Integer -> UrlOptions -> IO Bool
checkBoth url expected_size uo = do
	v <- check url expected_size uo
	return (fst v && snd v)
check :: URLString -> Maybe Integer -> UrlOptions -> IO (Bool, Bool)
check url expected_size = go <$$> getUrlInfo url
  where
	go (UrlInfo False _ _) = (False, False)
	go (UrlInfo True Nothing _) = (True, True)
	go (UrlInfo True s _) = case expected_size of
		Just _ -> (True, expected_size == s)
		Nothing -> (True, True)

exists :: URLString -> UrlOptions -> IO Bool
exists url uo = urlExists <$> getUrlInfo url uo

data UrlInfo = UrlInfo
	{ urlExists :: Bool
	, urlSize :: Maybe Integer
	, urlSuggestedFile :: Maybe FilePath
	}

{- Checks that an url exists and could be successfully downloaded,
 - also returning its size and suggested filename if available. -}
getUrlInfo :: URLString -> UrlOptions -> IO UrlInfo
getUrlInfo url uo = case parseURIRelaxed url of
	Just u -> case parseUrl (show u) of
		Just req -> existsconduit req `catchNonAsync` const dne
		-- http-conduit does not support file:, ftp:, etc urls,
		-- so fall back to reading files and using curl.
		Nothing
			| uriScheme u == "file:" -> do
				let f = unEscapeString (uriPath u)
				s <- catchMaybeIO $ getFileStatus f
				case s of
					Just stat -> do
						sz <- getFileSize' f stat
						found (Just sz) Nothing
					Nothing -> dne
			| Build.SysConfig.curl -> do
				output <- catchDefaultIO "" $
					readProcess "curl" $ toCommand curlparams
				case lastMaybe (lines output) of
					Just ('2':_:_) -> found
						(extractlencurl output)
						Nothing
					_ -> dne
			| otherwise -> dne
	Nothing -> dne
  where
	dne = return $ UrlInfo False Nothing Nothing
	found sz f = return $ UrlInfo True sz f

	curlparams = addUserAgent uo $
		[ Param "-s"
		, Param "--head"
		, Param "-L", Param url
		, Param "-w", Param "%{http_code}"
		] ++ concatMap (\h -> [Param "-H", Param h]) (reqHeaders uo) ++ (reqParams uo)

	extractlencurl s = case lastMaybe $ filter ("Content-Length:" `isPrefixOf`) (lines s) of
		Just l -> case lastMaybe $ words l of
			Just sz -> readish sz
			_ -> Nothing
		_ -> Nothing
	
	extractlen = readish . B8.toString <=< firstheader hContentLength

	extractfilename = contentDispositionFilename . B8.toString
		<=< firstheader hContentDisposition

	firstheader h = headMaybe . map snd .
		filter (\p -> fst p == h) . responseHeaders

	existsconduit req = withManager $ \mgr -> do
		let req' = headRequest (applyRequest uo req)
		resp <- http req' mgr
		-- forces processing the response before the
		-- manager is closed
		ret <- liftIO $ if responseStatus resp == ok200
			then found
				(extractlen resp)
				(extractfilename resp)
			else dne
		liftIO $ closeManager mgr
		return ret

-- Parse eg: attachment; filename="fname.ext"
-- per RFC 2616
contentDispositionFilename :: String -> Maybe FilePath
contentDispositionFilename s
	| "attachment; filename=\"" `isPrefixOf` s && "\"" `isSuffixOf` s =
		Just $ reverse $ drop 1 $ reverse $ 
			drop 1 $ dropWhile (/= '"') s
	| otherwise = Nothing

#if MIN_VERSION_http_conduit(2,0,0)
headRequest :: Request -> Request
#else
headRequest :: Request m -> Request m
#endif
headRequest r = r
	{ method = methodHead
	-- remove defaut Accept-Encoding header, to get actual,
	-- not gzip compressed size.
	, requestHeaders = (hAcceptEncoding, B.empty) :
		filter (\(h, _) -> h /= hAcceptEncoding)
		(requestHeaders r)
	}

{- Used to download large files, such as the contents of keys.
 -
 - Uses wget or curl program for its progress bar. (Wget has a better one,
 - so is preferred.) Which program to use is determined at run time; it
 - would not be appropriate to test at configure time and build support
 - for only one in.
 -}
download :: URLString -> FilePath -> UrlOptions -> IO Bool
download = download' False

{- No output, even on error. -}
downloadQuiet :: URLString -> FilePath -> UrlOptions -> IO Bool
downloadQuiet = download' True

download' :: Bool -> URLString -> FilePath -> UrlOptions -> IO Bool
download' quiet url file uo = 
	case parseURIRelaxed url of
		Just u
			| uriScheme u == "file:" -> do
				curl
			| otherwise -> ifM (inPath "wget") (wget , curl)
		_ -> return False
  where
	headerparams = map (\h -> Param $ "--header=" ++ h) (reqHeaders uo)
	wget = go "wget" $ headerparams ++ quietopt "-q" ++ wgetparams
	{- Regular wget needs --clobber to continue downloading an existing
	 - file. On Android, busybox wget is used, which does not
	 - support, or need that option.
	 -
	 - When the wget version is new enough, pass options for
	 - a less cluttered download display.
	 -}
#ifndef __ANDROID__
	wgetparams = catMaybes
		[ if Build.SysConfig.wgetquietprogress
			then Just $ Params "-q --show-progress"
			else Nothing
		, Just $ Params "--clobber -c -O"
		]
#else
	wgetparams = [Params "-c -O"]
#endif
	{- Uses the -# progress display, because the normal
	 - one is very confusing when resuming, showing
	 - the remainder to download as the whole file,
	 - and not indicating how much percent was
	 - downloaded before the resume. -}
	curl = do
		-- curl does not create destination file
		-- if the url happens to be empty, so pre-create.
		writeFile file ""
		go "curl" $ headerparams ++ quietopt "-s" ++
			[Params "-f -L -C - -# -o"]
	go cmd opts = boolSystem cmd $
		addUserAgent uo $ reqParams uo++opts++[File file, File url]
	quietopt s
		| quiet = [Param s]
		| otherwise = []

{- Allows for spaces and other stuff in urls, properly escaping them. -}
parseURIRelaxed :: URLString -> Maybe URI
parseURIRelaxed = parseURI . escapeURIString isAllowedInURI

hAcceptEncoding :: CI.CI B.ByteString
hAcceptEncoding = "Accept-Encoding"

hContentDisposition :: CI.CI B.ByteString
hContentDisposition = "Content-Disposition"

#if ! MIN_VERSION_http_types(0,7,0)
hContentLength :: CI.CI B.ByteString
hContentLength = "Content-Length"

hUserAgent :: CI.CI B.ByteString
hUserAgent = "User-Agent"
#endif

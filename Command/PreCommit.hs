{- git-annex command
 -
 - Copyright 2010-2014 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Command.PreCommit where

import Common.Annex
import Command
import Config
import qualified Command.Add
import qualified Command.Fix
import Annex.Direct
import Annex.Hook
import Annex.View
import Annex.View.ViewedFile
import Annex.LockFile
import Logs.View
import Logs.MetaData
import Types.View
import Types.MetaData
import qualified Git.Index as Git
import qualified Git.LsFiles as Git

import qualified Data.Set as S

cmd :: Command
cmd = command "pre-commit" SectionPlumbing
	"run by git pre-commit hook"
	paramPaths
	(withParams seek)

seek :: CmdParams -> CommandSeek
seek ps = lockPreCommitHook $ ifM isDirect
	( do
		-- update direct mode mappings for committed files
		withWords startDirect ps
		runAnnexHook preCommitAnnexHook
	, do
		ifM (liftIO Git.haveFalseIndex)
			( do
				(fs, cleanup) <- inRepo $ Git.typeChangedStaged ps
				whenM (anyM isUnlocked fs) $
					error "Cannot make a partial commit with unlocked annexed files. You should `git annex add` the files you want to commit, and then run git commit."
				void $ liftIO cleanup
			, do
				-- fix symlinks to files being committed
				withFilesToBeCommitted (whenAnnexed Command.Fix.start) ps
				-- inject unlocked files into the annex
				withFilesUnlockedToBeCommitted startIndirect ps
			)
		runAnnexHook preCommitAnnexHook
		-- committing changes to a view updates metadata
		mv <- currentView
		case mv of
			Nothing -> noop
			Just v -> withViewChanges
				(addViewMetaData v)
				(removeViewMetaData v)
	)
	

startIndirect :: FilePath -> CommandStart
startIndirect f = next $ do
	unlessM (callCommandAction $ Command.Add.start f) $
		error $ "failed to add " ++ f ++ "; canceling commit"
	next $ return True

startDirect :: [String] -> CommandStart
startDirect _ = next $ next preCommitDirect

addViewMetaData :: View -> ViewedFile -> Key -> CommandStart
addViewMetaData v f k = do
	showStart "metadata" f
	next $ next $ changeMetaData k $ fromView v f

removeViewMetaData :: View -> ViewedFile -> Key -> CommandStart
removeViewMetaData v f k = do
	showStart "metadata" f
	next $ next $ changeMetaData k $ unsetMetaData $ fromView v f

changeMetaData :: Key -> MetaData -> CommandCleanup
changeMetaData k metadata = do
	showMetaDataChange metadata
	addMetaData k metadata
	return True

showMetaDataChange :: MetaData -> Annex ()
showMetaDataChange = showLongNote . unlines . concatMap showmeta . fromMetaData
  where
	showmeta (f, vs) = map (showmetavalue f) $ S.toList vs
	showmetavalue f v = fromMetaField f ++ showset v ++ "=" ++ fromMetaValue v
	showset v
		| isSet v = "+"
		| otherwise = "-"

{- Takes exclusive lock; blocks until available. -}
lockPreCommitHook :: Annex a -> Annex a
lockPreCommitHook = withExclusiveLock gitAnnexPreCommitLock

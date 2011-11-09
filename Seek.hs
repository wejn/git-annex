{- git-annex command seeking
 - 
 - These functions find appropriate files or other things based on
 - the values a user passes to a command, and prepare actions operating
 - on them.
 -
 - Copyright 2010-2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Seek where

import Common.Annex
import Types.Command
import Types.Key
import Backend
import qualified Annex
import qualified Git
import qualified Git.LsFiles as LsFiles
import qualified Limit

seekHelper :: ([FilePath] -> Git.Repo -> IO [FilePath]) -> [FilePath] -> Annex [FilePath]
seekHelper a params = do
	g <- gitRepo
	liftIO $ runPreserveOrder (\p -> a p g) params

withFilesInGit :: (FilePath -> CommandStart) -> CommandSeek
withFilesInGit a params = prepFiltered a $ seekHelper LsFiles.inRepo params

withAttrFilesInGit :: String -> ((FilePath, String) -> CommandStart) -> CommandSeek
withAttrFilesInGit attr a params = do
	files <- seekHelper LsFiles.inRepo params
	prepFilteredGen a fst $ inRepo $ Git.checkAttr attr files

withNumCopies :: (FilePath -> Maybe Int -> CommandStart) -> CommandSeek
withNumCopies a params = withAttrFilesInGit "annex.numcopies" go params
	where
		go (file, v) = a file (readMaybe v)

withBackendFilesInGit :: (BackendFile -> CommandStart) -> CommandSeek
withBackendFilesInGit a params = do
	files <- seekHelper LsFiles.inRepo params
	prepBackendPairs a files

withFilesMissing :: (String -> CommandStart) -> CommandSeek
withFilesMissing a params = prepFiltered a $ liftIO $ filterM missing params
	where
		missing = liftM not . doesFileExist

withFilesNotInGit :: (BackendFile -> CommandStart) -> CommandSeek
withFilesNotInGit a params = do
	force <- Annex.getState Annex.force
	newfiles <- seekHelper (LsFiles.notInRepo force) params
	prepBackendPairs a newfiles

withWords :: ([String] -> CommandStart) -> CommandSeek
withWords a params = return [a params]

withStrings :: (String -> CommandStart) -> CommandSeek
withStrings a params = return $ map a params

withFilesToBeCommitted :: (String -> CommandStart) -> CommandSeek
withFilesToBeCommitted a params = prepFiltered a $
	seekHelper LsFiles.stagedNotDeleted params

withFilesUnlocked :: (BackendFile -> CommandStart) -> CommandSeek
withFilesUnlocked = withFilesUnlocked' LsFiles.typeChanged

withFilesUnlockedToBeCommitted :: (BackendFile -> CommandStart) -> CommandSeek
withFilesUnlockedToBeCommitted = withFilesUnlocked' LsFiles.typeChangedStaged

withFilesUnlocked' :: ([FilePath] -> Git.Repo -> IO [FilePath]) -> (BackendFile -> CommandStart) -> CommandSeek
withFilesUnlocked' typechanged a params = do
	-- unlocked files have changed type from a symlink to a regular file
	top <- fromRepo $ Git.workTree
	typechangedfiles <- seekHelper typechanged params
	unlockedfiles <- liftIO $ filterM notSymlink $
		map (\f -> top ++ "/" ++ f) typechangedfiles
	prepBackendPairs a unlockedfiles

withKeys :: (Key -> CommandStart) -> CommandSeek
withKeys a params = return $ map (a . parse) params
	where
		parse p = fromMaybe (error "bad key") $ readKey p

withNothing :: CommandStart -> CommandSeek
withNothing a [] = return [a]
withNothing _ _ = error "This command takes no parameters."


prepFiltered :: (FilePath -> CommandStart) -> Annex [FilePath] -> Annex [CommandStart]
prepFiltered a = prepFilteredGen a id

prepBackendPairs :: (BackendFile -> CommandStart) -> CommandSeek
prepBackendPairs a fs = prepFilteredGen a snd (chooseBackends fs)

prepFilteredGen :: (b -> CommandStart) -> (b -> FilePath) -> Annex [b] -> Annex [CommandStart]
prepFilteredGen a d fs = do
	matcher <- Limit.getMatcher
	prepStart (proc matcher) fs
	where
		proc matcher v = do
			let f = d v
			ok <- matcher f
			if ok then a v else return Nothing

{- Generates a list of CommandStart actions that will be run to perform a
 - command, using a list (ie of files) coming from an action. The list
 - will be produced and consumed lazily. -}
prepStart :: (b -> CommandStart) -> Annex [b] -> Annex [CommandStart]
prepStart a fs = liftM (map a) fs

notSymlink :: FilePath -> IO Bool
notSymlink f = liftIO $ not . isSymbolicLink <$> getSymbolicLinkStatus f
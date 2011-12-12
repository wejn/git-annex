{- management of the git-annex branch
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.Branch (
	create,
	update,
	get,
	change,
	commit,
	files,
	name,
	hasOrigin,
	hasSibling,
) where

import System.Exit
import qualified Data.ByteString.Lazy.Char8 as L

import Common.Annex
import Annex.Exception
import Annex.BranchState
import Annex.Journal
import qualified Git
import qualified Git.UnionMerge
import qualified Git.Ref
import Annex.CatFile

{- Name of the branch that is used to store git-annex's information. -}
name :: Git.Ref
name = Git.Ref "git-annex"

{- Fully qualified name of the branch. -}
fullname :: Git.Ref
fullname = Git.Ref $ "refs/heads/" ++ show name

{- Branch's name in origin. -}
originname :: Git.Ref
originname = Git.Ref $ "origin/" ++ show name

{- Populates the branch's index file with the current branch contents.
 - 
 - This is only done when the index doesn't yet exist, and the index 
 - is used to build up changes to be commited to the branch, and merge
 - in changes from other branches.
 -}
genIndex :: Git.Repo -> IO ()
genIndex g = Git.UnionMerge.stream_update_index g
	[Git.UnionMerge.ls_tree fullname g]

{- Merges the specified branches into the index.
 - Any changes staged in the index will be preserved. -}
mergeIndex :: [Git.Ref] -> Annex ()
mergeIndex branches = do
	h <- catFileHandle
	inRepo $ \g -> Git.UnionMerge.merge_index h g branches

{- Runs an action using the branch's index file. -}
withIndex :: Annex a -> Annex a
withIndex = withIndex' False
withIndex' :: Bool -> Annex a -> Annex a
withIndex' bootstrapping a = do
	f <- fromRepo gitAnnexIndex
	bracketIO (Git.useIndex f) id $ do
		unlessM (liftIO $ doesFileExist f) $ do
			unless bootstrapping create
			liftIO $ createDirectoryIfMissing True $ takeDirectory f
			unless bootstrapping $ inRepo genIndex
		a

{- Updates the branch's index to reflect the current contents of the branch.
 - Any changes staged in the index will be preserved.
 -
 - Compares the ref stored in the lock file with the current
 - ref of the branch to see if an update is needed.
 -}
updateIndex :: Git.Ref -> Annex ()
updateIndex branchref = do
	lock <- fromRepo gitAnnexIndexLock
	lockref <- Git.Ref . firstLine <$>
		liftIO (catchDefaultIO (readFileStrict lock) "")
	when (lockref /= branchref) $ do
		withIndex $ mergeIndex [fullname]
		setIndexSha branchref

{- Record that the branch's index has been updated to correspond to a
 - given ref of the branch. -}
setIndexSha :: Git.Ref -> Annex ()
setIndexSha ref = do
        lock <- fromRepo gitAnnexIndexLock
	liftIO $ writeFile lock $ show ref ++ "\n"

{- Commits the staged changes in the index to the branch.
 - 
 - Ensures that the branch's index file is first updated to the state
 - of the brannch at branchref, before running the commit action. This
 - is needed because the branch may have had changes pushed to it, that
 - are not yet reflected in the index.
 -
 - Also safely handles a race that can occur if a change is being pushed
 - into the branch at the same time. When the race happens, the commit will
 - be made on top of the newly pushed change, but without the index file
 - being updated to include it. The result is that the newly pushed
 - change is reverted. This race is detected and another commit made
 - to fix it.
 - 
 - The branchref value can have been obtained using getBranch at any
 - previous point, though getting it a long time ago makes the race
 - more likely to occur.
 -}
commitBranch :: Git.Ref -> String -> [Git.Ref] -> Annex ()
commitBranch branchref message parents = do
	updateIndex branchref
	committedref <- inRepo $ Git.commit message fullname parents
	setIndexSha committedref
	parentrefs <- commitparents <$> catObject committedref
	when (racedetected branchref parentrefs) $
		fixrace committedref parentrefs
	where
		-- look for "parent ref" lines and return the refs
		commitparents = map (Git.Ref . snd) . filter isparent .
			map (toassoc . L.unpack) . L.lines
		toassoc = separate (== ' ')
		isparent (k,_) = k == "parent"
		
 		{- The race can be detected by checking the commit's
		 - parent, which will be the newly pushed branch,
		 - instead of the expected ref that the index was updated to. -}
		racedetected expectedref parentrefs
			| expectedref `elem` parentrefs = False -- good parent
			| otherwise = True -- race!
		
		{- To recover from the race, union merge the lost refs
		 - into the index, and recommit on top of the bad commit. -}
		fixrace committedref lostrefs = do
			mergeIndex lostrefs
			commitBranch committedref racemessage [committedref]
		
		racemessage = message ++ " (recovery from race)"

{- Runs an action using the branch's index file, first making sure that
 - the branch and index are up-to-date. -}
withIndexUpdate :: Annex a -> Annex a
withIndexUpdate a = update >> withIndex a

{- Creates the branch, if it does not already exist. -}
create :: Annex ()
create = do
	_ <- getBranch
	return ()

{- Returns the ref of the branch, creating it first if necessary. -}
getBranch :: Annex (Git.Ref)
getBranch = maybe (hasOrigin >>= go >>= use) (return) =<< branchsha
	where
		go True = do
			inRepo $ Git.run "branch"
				[Param $ show name, Param $ show originname]
			fromMaybe (error $ "failed to create " ++ show name)
				<$> branchsha
		go False = withIndex' True $ do
			inRepo $ Git.commit "branch created" fullname []
		use sha = do
			setIndexSha sha
			return sha
		branchsha = inRepo $ Git.Ref.sha fullname

{- Stages the journal, and commits staged changes to the branch. -}
commit :: String -> Annex ()
commit message = whenM journalDirty $ lockJournal $ do
	stageJournal
	ref <- getBranch
	withIndex $ commitBranch ref message [fullname]

{- Ensures that the branch and index are is up-to-date; should be
 - called before data is read from it. Runs only once per git-annex run.
 -
 - Before refs are merged into the index, it's important to first stage the
 - journal into the index. Otherwise, any changes in the journal would
 - later get staged, and might overwrite changes made during the merge.
 -
 - (It would be cleaner to handle the merge by updating the journal, not the
 - index, with changes from the branches.)
 -
 - The branch is fast-forwarded if possible, otherwise a merge commit is
 - made.
 -}
update :: Annex ()
update = runUpdateOnce $ do
	-- ensure branch exists, and get its current ref
	branchref <- getBranch
	-- check what needs updating before taking the lock
	dirty <- journalDirty
	c <- filterM (changedBranch fullname . snd) =<< siblingBranches
	let (refs, branches) = unzip c
	if (not dirty && null refs)
		then updateIndex branchref
		else withIndex $ lockJournal $ do
			when dirty stageJournal
			let merge_desc = if null branches
				then "update" 
				else "merging " ++
					unwords (map Git.Ref.describe branches) ++ 
					" into " ++ show name
			unless (null branches) $ do
				showSideAction merge_desc
				mergeIndex branches
			ff <- if dirty then return False else tryFastForwardTo refs
			if ff
				then updateIndex branchref
				else commitBranch branchref merge_desc
					(nub $ fullname:refs)
			invalidateCache

{- Checks if the second branch has any commits not present on the first
 - branch. -}
changedBranch :: Git.Branch -> Git.Branch -> Annex Bool
changedBranch origbranch newbranch
	| origbranch == newbranch = return False
	| otherwise = not . L.null <$> diffs
	where
		diffs = inRepo $ Git.pipeRead
			[ Param "log"
			, Param (show origbranch ++ ".." ++ show newbranch)
			, Params "--oneline -n1"
			]

{- Given a set of refs that are all known to have commits not
 - on the git-annex branch, tries to update the branch by a
 - fast-forward.
 -
 - In order for that to be possible, one of the refs must contain
 - every commit present in all the other refs, as well as in the
 - git-annex branch.
 -}
tryFastForwardTo :: [Git.Ref] -> Annex Bool
tryFastForwardTo [] = return True
tryFastForwardTo (first:rest) = do
	-- First, check that the git-annex branch does not contain any
	-- new commits that are not in the first other branch. If it does,
	-- cannot fast-forward.
	diverged <- changedBranch first fullname
	if diverged
		then no_ff
		else maybe no_ff do_ff =<< findbest first rest
	where
		no_ff = return False
		do_ff branch = do
			inRepo $ Git.run "update-ref"
				[Param $ show fullname, Param $ show branch]
			return True
		findbest c [] = return $ Just c
		findbest c (r:rs)
			| c == r = findbest c rs
			| otherwise = do
			better <- changedBranch c r
			worse <- changedBranch r c
			case (better, worse) of
				(True, True) -> return Nothing -- divergent fail
				(True, False) -> findbest r rs -- better
				(False, True) -> findbest c rs -- worse
				(False, False) -> findbest c rs -- same
			
{- Does origin/git-annex exist? -}
hasOrigin :: Annex Bool
hasOrigin = inRepo $ Git.Ref.exists originname

{- Does the git-annex branch or a sibling foo/git-annex branch exist? -}
hasSibling :: Annex Bool
hasSibling = not . null <$> siblingBranches

{- List of git-annex (refs, branches), including the main one and any
 - from remotes. Duplicate refs are filtered out. -}
siblingBranches :: Annex [(Git.Ref, Git.Branch)]
siblingBranches = inRepo $ Git.Ref.matching name

{- Applies a function to modifiy the content of a file.
 -
 - Note that this does not cause the branch to be merged, it only
 - modifes the current content of the file on the branch.
 -}
change :: FilePath -> (String -> String) -> Annex ()
change file a = lockJournal $ getStale file >>= return . a >>= set file

{- Records new content of a file into the journal and cache. -}
set :: FilePath -> String -> Annex ()
set file content = do
	setJournalFile file content
	setCache file content

{- Gets the content of a file on the branch, or content from the journal, or
 - staged in the index.
 -
 - Returns an empty string if the file doesn't exist yet. -}
get :: FilePath -> Annex String
get = get' False

{- Like get, but does not merge the branch, so the info returned may not
 - reflect changes in remotes. (Changing the value this returns, and then
 - merging is always the same as using get, and then changing its value.) -}
getStale :: FilePath -> Annex String
getStale = get' True

get' :: Bool -> FilePath -> Annex String
get' staleok file = fromcache =<< getCache file
	where
		fromcache (Just content) = return content
		fromcache Nothing = fromjournal =<< getJournalFile file
		fromjournal (Just content) = cache content
		fromjournal Nothing
			| staleok = withIndex frombranch
			| otherwise = withIndexUpdate $ frombranch >>= cache
		frombranch = L.unpack <$> catFile fullname file
		cache content = do
			setCache file content
			return content

{- Lists all files on the branch. There may be duplicates in the list. -}
files :: Annex [FilePath]
files = withIndexUpdate $ do
	bfiles <- inRepo $ Git.pipeNullSplit
		[Params "ls-tree --name-only -r -z", Param $ show fullname]
	jfiles <- getJournalledFiles
	return $ jfiles ++ bfiles

{- Stages the journal into the index. -}
stageJournal :: Annex ()
stageJournal = do
	fs <- getJournalFiles
	g <- gitRepo
	withIndex $ liftIO $ do
		let dir = gitAnnexJournalDir g
		let paths = map (dir </>) fs
		-- inject all the journal files directly into git
		-- in one quick command
		(pid, fromh, toh) <- hPipeBoth "git" $ toCommand $ git_hash_object g
		_ <- forkProcess $ do
			hPutStr toh $ unlines paths
			hClose toh
			exitSuccess
		hClose toh
		shas <- map Git.Ref . lines <$> hGetContents fromh
		-- update the index, also in just one command
		Git.UnionMerge.update_index g $
			index_lines shas (map fileJournal fs)
		hClose fromh
		forceSuccess pid
		mapM_ removeFile paths
	where
		index_lines shas = map genline . zip shas
		genline (sha, file) = Git.UnionMerge.update_index_line sha file
		git_hash_object = Git.gitCommandLine
			[Param "hash-object", Param "-w", Param "--stdin-paths"]

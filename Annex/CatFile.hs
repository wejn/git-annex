{- git cat-file interface, with handle automatically stored in the Annex monad
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.CatFile (
	catFile,
	catObject,
	catFileHandle
) where

import qualified Data.ByteString.Lazy.Char8 as L

import Common.Annex
import qualified Git
import qualified Git.CatFile
import qualified Annex

catFile :: Git.Branch -> FilePath -> Annex L.ByteString
catFile branch file = do
	h <- catFileHandle
	liftIO $ Git.CatFile.catFile h branch file

catObject :: Git.Ref -> Annex L.ByteString
catObject ref = do
	h <- catFileHandle
	liftIO $ Git.CatFile.catObject h ref

catFileHandle :: Annex Git.CatFile.CatFileHandle
catFileHandle = maybe startup return =<< Annex.getState Annex.catfilehandle
	where
		startup = do
			h <- inRepo Git.CatFile.catFileStart
			Annex.changeState $ \s -> s { Annex.catfilehandle = Just h }
			return h

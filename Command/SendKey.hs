{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.SendKey where

import Common.Annex
import Command
import Annex.Content
import Utility.RsyncFile

def :: [Command]
def = [oneShot $ command "sendkey" paramKey seek
	"runs rsync in server mode to send content"]

seek :: [CommandSeek]
seek = [withKeys start]

start :: Key -> CommandStart
start key = do
	file <- inRepo $ gitAnnexLocation key
	whenM (inAnnex key) $
		liftIO $ rsyncServerSend file -- does not return
	warning "requested key is not present"
	liftIO exitFailure

{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PackageImports             #-}
{-# LANGUAGE ViewPatterns               #-}

module Thentos
    ( main
    , makeMain
    , createConnPoolAndInitDb
    , createDefaultUser
    , autocreateMissingServices
    ) where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar (newMVar)
import Control.Concurrent (ThreadId, threadDelay, forkIO)
import Control.Exception (finally)
import Control.Monad (void, when, forever)
import "cryptonite" Crypto.Random (drgNew)
import Database.PostgreSQL.Simple (Connection, connectPostgreSQL, close)
import Data.Configifier ((>>.), Tagged(Tagged))
import Data.Either (isRight)
import Data.Maybe (maybeToList)
import Data.Monoid ((<>))
import Data.Pool (Pool, createPool, withResource)
import Data.Proxy (Proxy(Proxy))
import Data.String.Conversions (SBS, cs)
import Data.Void (Void)
import LIO.DCLabel (toCNF)
import System.Log.Logger (Priority(DEBUG, INFO, ERROR), removeAllHandlers)
import Text.Show.Pretty (ppShow)

import qualified Data.Map as Map

import System.Log.Missing (logger, announceAction)
import Thentos.Action
import Thentos.Action.Core (Action, ActionState(..), runActionWithPrivs)
import Thentos.Config
import Thentos.Frontend (runFrontend)
import Thentos.Smtp (checkSendmail)
import Thentos.Transaction.Core (createDB, runThentosQuery, ThentosQuery)
import Thentos.Types
import Thentos.Util

import qualified Thentos.Backend.Api.Simple as Simple
import qualified Thentos.Transaction as T


-- * main

main :: IO ()
main = makeMain $ \ actionState mBeConfig mFeConfig -> do
    let backend = maybe (return ())
            (`Simple.runApi` actionState)
            mBeConfig
    let frontend = maybe (return ())
            (`runFrontend` actionState)
            mFeConfig

    void $ concurrently backend frontend


-- * main with abstract commands

makeMain :: (ActionState -> Maybe HttpConfig -> Maybe HttpConfig -> IO ()) -> IO ()
makeMain commandSwitch =
  do
    config <- getConfig "devel.config"
    checkSendmail (Tagged $ config >>. (Proxy :: Proxy '["smtp"]))

    rng <- drgNew >>= newMVar
    let dbName = config >>. (Proxy :: Proxy '["database", "name"])
    connPool <- createConnPoolAndInitDb $ cs dbName
    let actionState = ActionState (connPool, rng, config)
        logPath     = config >>. (Proxy :: Proxy '["log", "path"])
        logLevel    = config >>. (Proxy :: Proxy '["log", "level"])
    configLogger logPath logLevel
    _ <- runGcLoop actionState $ config >>. (Proxy :: Proxy '["gc_interval"])
    withResource connPool $ \conn ->
        createDefaultUser conn (Tagged <$> config >>. (Proxy :: Proxy '["default_user"]))
    _ <- runActionWithPrivs [toCNF RoleAdmin] () actionState
        (autocreateMissingServices config :: Action Void () ())

    let mBeConfig :: Maybe HttpConfig
        mBeConfig = Tagged <$> config >>. (Proxy :: Proxy '["backend"])

        mFeConfig :: Maybe HttpConfig
        mFeConfig = Tagged <$> config >>. (Proxy :: Proxy '["frontend"])

    logger INFO "Press ^C to abort."
    let run = do
            commandSwitch actionState mBeConfig mFeConfig
        finalize = do
            announceAction "shutting down hslogger" $
                removeAllHandlers

    run `finally` finalize


-- * helpers

-- | Garbage collect DB type.  (In this module because 'Thentos.Util' doesn't have 'Thentos.Action'
-- yet.  It takes the time interval in such a weird type so that it's easier to call with the
-- config.  This function should move and change in the future.)
runGcLoop :: ActionState -> Maybe Timeout -> IO ThreadId
runGcLoop _           Nothing         = forkIO $ return ()
runGcLoop actionState (Just interval) = forkIO . forever $ do
    _ <- runActionWithPrivs [toCNF RoleAdmin] () actionState (collectGarbage :: Action Void () ())
    threadDelay $ toMilliseconds interval * 1000

-- | Create a connection pool and initialize the DB by creating all tables, indexes etc. if the DB
-- is empty. Tables already existing in the DB won't be touched. The DB itself must already exist.
createConnPoolAndInitDb :: SBS -> IO (Pool Connection)
createConnPoolAndInitDb dbName = do
    connPool <- createPool createConn close
                           1    -- # of stripes (sub-pools)
                           60   -- close unused connections after .. secs
                           100  -- max number of active connections
    withResource connPool createDB
    return connPool
  where
    createConn = connectPostgreSQL $ "dbname=" <> dbName

-- | If default user is 'Nothing' or user with 'UserId 0' exists, do
-- nothing.  Otherwise, create default user.
createDefaultUser :: Connection -> Maybe DefaultUserConfig -> IO ()
createDefaultUser _ Nothing = return ()
createDefaultUser conn (Just (getDefaultUser -> (userData, roles))) = do
    eq <- runThentosQuery conn $ (void $ T.lookupConfirmedUser (UserId 0) :: ThentosQuery Void ())
    case eq of
        Right _         -> logger DEBUG $ "default user already exists"
        Left NoSuchUser -> do
            -- user
            user <- makeUserFromFormData userData
            logger DEBUG $ "No users.  Creating default user: " ++ ppShow (UserId 0, user)
            eu <- runThentosQuery conn $ T.addUserPrim
                    (Just $ UserId 0) user True

            if eu == (Right (UserId 0) :: Either (ThentosError Void) UserId)
                then logger DEBUG $ "[ok]"
                else logger ERROR $ "failed to create default user: " ++ ppShow (UserId 0, eu, user)

            -- roles
            logger DEBUG $ "Adding default user to roles: " ++ ppShow roles
            result <-
                 mapM (runThentosQuery conn . T.assignRole (UserA . UserId $ 0)) roles

            if all isRight (result :: [Either (ThentosError Void) ()])
                then logger DEBUG $ "[ok]"
                else logger ERROR $ "failed to assign default user to roles: " ++ ppShow (UserId 0, result, user, roles)
        Left e          -> logger ERROR $ "error looking up default user: " ++ show e

-- | Autocreate any services that are listed in the config but don't exist in the DB.
-- Dies with an error if the default "proxy" service ID is repeated in the "proxies" section.
autocreateMissingServices :: ThentosConfig -> Action Void s ()
autocreateMissingServices cfg = do
    dieOnDuplicates
    mapM_ (autocreateServiceIfMissing'P agent) allSids
  where
    dieOnDuplicates  = case mDefaultProxySid of
        Just sid -> when (sid `elem` proxySids) . error $ show sid ++ " mentioned twice in config"
        Nothing  -> return ()
    allSids          = maybeToList mDefaultProxySid ++ proxySids
    mDefaultProxySid = ServiceId <$> cfg >>. (Proxy :: Proxy '["proxy", "service_id"])
    proxySids        = Map.keys $ getProxyConfigMap cfg
    agent            = UserId 0

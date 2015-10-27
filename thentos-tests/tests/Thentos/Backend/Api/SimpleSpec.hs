{-# LANGUAGE ExistentialQuantification                #-}
{-# LANGUAGE FlexibleContexts                         #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE GADTs                                    #-}
{-# LANGUAGE InstanceSigs                             #-}
{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE RankNTypes                               #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TupleSections                            #-}
{-# LANGUAGE TypeSynonymInstances                     #-}

module Thentos.Backend.Api.SimpleSpec (spec, tests)
where

import Control.Monad (void)
import Control.Monad.State (liftIO)
import Data.Monoid ((<>))
import Data.Pool (withResource)
import Data.IORef (IORef, newIORef, writeIORef, readIORef)
import Data.String.Conversions (LBS, cs)
import Network.Wai (Application)
import Network.Wai.Test (simpleBody, SResponse)
import Network.HTTP.Types.Header (Header)
import Test.Hspec (Spec, SpecWith, describe, it, shouldBe, shouldContain, pendingWith, hspec)
import Test.Hspec.Wai (shouldRespondWith, WaiSession, with, request, matchStatus)

import qualified Data.Aeson as Aeson
import System.IO.Unsafe (unsafePerformIO)
import Network.HTTP.Types.Status ()

import Thentos.Backend.Api.Simple (serveApi)
import Thentos.Types
import Thentos.Action.Core
import Thentos.Util (getJsDir)

import Thentos.Test.Core
import Thentos.Test.Config


defaultApp :: IO Application
defaultApp = do
    db@(ActionState (connPool, _, _)) <- createActionState "test_thentos" thentosTestConfig
    withResource connPool createGod
    writeIORef godHeaders . snd =<< loginAsGod db
    jsDir <- getJsDir
    return $! serveApi db jsDir

tests :: IO ()
tests = hspec spec

godHeaders :: IORef [Header]
godHeaders = unsafePerformIO $ newIORef []
{-# NOINLINE godHeaders #-}

spec :: Spec
spec = do
    describe "Thentos.Backend.Api.Simple" . with defaultApp $ do
        specRest
        specPurescript

specRest :: SpecWith Application
specRest= do
    describe "headers" $ do
        it "bad unknown headers matching /X-Thentos-*/ yields an error response." $ do
            hdr <- liftIO ctHeader
            let headers = ("X-Thentos-No-Such-Header", "3"):hdr
            request "GET" "/user/0/email" headers "" `shouldRespondWith` 400

    describe "user" $ do
        describe "Capture \"userid\" UserId :> \"name\" :> Get UserName" $ do
            let resource = "/user/0/name"
            it "yields a name" $ do
                hdr <- liftIO ctHeader
                request "GET" resource hdr "" `shouldRespondWith` "\"god\""

            it "can be called by user herself" $
                    \ _ -> pendingWith "test missing."

            it "can be called by admin" $ do
                hdr <- liftIO ctHeader
                request "GET" resource hdr "" `shouldRespondWith` 200

            it "can not be called by other (non-admin) users" $
                    \ _ -> pendingWith "test missing."

        describe "Capture \"userid\" UserId :> \"email\" :> Get UserEmail" $ do
            let resource = "/user/0/email"
            it "yields an email address" $ do
                hdr <- liftIO ctHeader
                request "GET" resource hdr "" `shouldRespondWith` 200

        describe "ReqBody UserFormData :> Post UserId" $ do
            it "writes a new user to the database" $ do
                hdr <- liftIO ctHeader
                response1 <- postDefaultUser
                return response1 `shouldRespondWith` 201

                let (uid :: Int) = read . cs $ simpleBody response1
                response2 <- request "GET" ("/user/" <> (cs . show $ uid) <> "/name") hdr ""

                let Right name = decodeLenient $ simpleBody response2
                liftIO $ name `shouldBe` udName defaultUserData

            it "can only be called by admins" $
                    \ _ -> pendingWith "test missing."

        describe "Capture \"userid\" UserId :> Delete" $ do
            it "removes an existing user from the database" $ do
                hdr <- liftIO ctHeader
                response1 <- postDefaultUser
                let (uid :: Int) = read . cs $ simpleBody response1
                request "GET" ("/user/" <> (cs . show $ uid) <> "/name") hdr ""
                    `shouldRespondWith` 200
                void $ request "DELETE" ("/user/" <> cs (show uid)) hdr ""
                request "GET" ("/user/" <> cs (show uid) <> "/name") hdr ""
                    `shouldRespondWith` 404

            it "can only be called by admins and the user herself" $
                    \ _ -> pendingWith "test missing."

            it "if user does not exist, responds with a 404" $ do
                hdr <- liftIO ctHeader
                request "DELETE" "/user/1797" hdr "" `shouldRespondWith` 404

    describe "thentos_session" $ do
        describe "ReqBody '[JSON] ThentosSessionToken :> Get Bool" $ do
            it "returns true if session is active" $ do
                hdr <- liftIO ctHeader
                response1 <- postDefaultUser
                let uid = read . cs $ simpleBody response1
                response2 <- request "POST" "/thentos_session" hdr $
                    Aeson.encode $ ByUser (UserId uid, udPassword defaultUserData)
                request "GET" "/thentos_session/" hdr (simpleBody response2)
                    `shouldRespondWith` "true" { matchStatus = 200 }

            it "returns false if session is does not exist" $ do
                void postDefaultUser
                hdr <- liftIO ctHeader
                request "GET" "/thentos_session/" hdr (Aeson.encode ("x" :: ThentosSessionToken))
                    `shouldRespondWith` "false" { matchStatus = 200 }


specPurescript :: SpecWith Application
specPurescript = do
    describe "purescript" $ do
        describe "/js/*.js" $ do
            it "is available" $ do
                request "GET" "/js/thentos.js" [] ""
                    `shouldRespondWith` 200

            it "has the right content type" $ do
                resp <- request "GET" "/js/thentos.js" [] ""
                liftIO $ cs (simpleBody resp) `shouldContain` ("PS[\"Main\"].main();" :: String)


postDefaultUser :: WaiSession SResponse
postDefaultUser = do
    hdr <- liftIO ctHeader
    request "POST" "/user" hdr (Aeson.encode defaultUserData)

-- | God Headers plus content-type = json
ctHeader :: IO [Header]
ctHeader = (("Content-Type", "application/json") :) <$> readIORef godHeaders

defaultUserData :: UserFormData
defaultUserData = UserFormData "name" "pwd" $ forceUserEmail "somebody@example.org"

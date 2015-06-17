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
{-# LANGUAGE ViewPatterns                             #-}

module Thentos.Backend.Api.Adhocracy3Spec
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Acid.Advanced (query')
import Data.Functor ((<$>))
import Data.String.Conversions (LBS, ST, (<>))
import Network.Wai.Test (srequest, simpleStatus, simpleBody)
import Test.Hspec (Spec, describe, it, before, after, shouldBe, shouldSatisfy, pendingWith, hspec)
import Test.QuickCheck (property)
import Data.Aeson (object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)

import qualified Data.Aeson as Aeson
import qualified Data.Map as Map
import qualified Data.Text as ST
import qualified Network.HTTP.Types.Status as C

import Thentos.Action.Core
import Thentos.Backend.Api.Adhocracy3
import Thentos.Config
import Thentos.Types

import qualified Thentos.Transaction as T

import Test.Arbitrary ()
import Test.Core
import Test.Types


tests :: IO ()
tests = hspec spec

spec :: Spec
spec =
    describe "Thentos.Backend.Api.Adhocracy3" $ do
        describe "A3UserNoPass" $ do
            it "has invertible *JSON instances" . property $
                let (===) (Right (A3UserNoPass (UserFormData n _ e)))
                          (Right (A3UserNoPass (UserFormData n' _ e')))
                              = n == n' && e == e'
                    (===) _ _ = False
                in \ (A3UserNoPass -> u) -> (Aeson.eitherDecode . Aeson.encode) u === Right u

        describe "A3UserWithPassword" $ do
            it "has invertible *JSON instances" . property $
                \ (A3UserWithPass -> u) -> (Aeson.eitherDecode . Aeson.encode) u == Right u

            it "rejects short passwords" $ do
                 let userdata = mkUserJson "Anna Müller" "anna@example.org" "short"
                 fromA3UserWithPass <$>
                     (Aeson.eitherDecode userdata :: Either String A3UserWithPass)
                     `shouldBe` Left "password too short (less than 6 characters)"

            it "rejects long passwords" $ do
                 let longpass = ST.replicate 26 "long"
                     userdata = mkUserJson "Anna Müller" "anna@example.org" longpass
                 fromA3UserWithPass <$>
                     (Aeson.eitherDecode userdata :: Either String A3UserWithPass)
                     `shouldBe` Left "password too long (more than 100 characters)"

            it "rejects invalid email addresses" $ do
                 let userdata = mkUserJson "Anna Müller" "anna@" "EckVocUbs3"
                 fromA3UserWithPass <$>
                     (Aeson.eitherDecode userdata :: Either String A3UserWithPass)
                     `shouldBe` Left "Not a valid email address: anna@"

            it "rejects empty user names" $ do
                 let userdata = mkUserJson "" "anna@example.org" "EckVocUbs3"
                 fromA3UserWithPass <$>
                     (Aeson.eitherDecode userdata :: Either String A3UserWithPass)
                     `shouldBe` Left "user name is empty"

            it "rejects user names with @" $ do
                 let userdata = mkUserJson "Bla@Blub" "anna@example.org" "EckVocUbs3"
                 fromA3UserWithPass <$>
                     (Aeson.eitherDecode userdata :: Either String A3UserWithPass)
                     `shouldBe` Left "'@' in user name is not allowed: \"Bla@Blub\""

            it "rejects user names with too much whitespace" $ do
                 let userdata = mkUserJson " Anna  Toll" "anna@example.org" "EckVocUbs3"
                 fromA3UserWithPass <$>
                     (Aeson.eitherDecode userdata :: Either String A3UserWithPass)
                     `shouldBe` Left "Illegal whitespace sequence in user name: \" Anna  Toll\""

        describe "create user" . before (setupTestBackend RunA3) . after teardownTestBackend $
            it "works" $
                \ bts@(BTS _ (ActionState (st, _, _)) _ _ _) -> runTestBackend bts $ do

                    let rq1 = mkUserJson "Anna Müller" "anna@example.org" "EckVocUbs3"

                    -- Appending trailing newline since servant-server < 0.4.1 couldn't handle it
                    rsp1 <- srequest $ makeSRequest "POST" "/principals/users" [] $ rq1 <> "\n"
                    liftIO $ C.statusCode (simpleStatus rsp1) `shouldBe` 201

                    Right (db :: DB) <- query' st T.SnapShot
                    let [(ConfirmationToken confTok, _)] = Map.toList $ db ^. dbUnconfirmedUsers

                    let rq2 = Aeson.encode . ActivationRequest . Path $ "/activate/" <> confTok
                    rsp2 <- srequest $ makeSRequest "POST" "/activate_account" [] rq2
                    liftIO $ C.statusCode (simpleStatus rsp2) `shouldBe` 201

                    let sessTok = case Aeson.eitherDecode $ simpleBody rsp2 of
                          Right (RequestSuccess _ t) -> t
                          bad -> error $ show bad

                    liftIO $ sessTok `shouldSatisfy` (not . ST.null . fromThentosSessionToken)

                    -- we should also do something with the token.
                    -- use proxy!  (this means this test requires a3
                    -- backend to run!)

                    return ()

        -- FIXME currently not working because of Servant quirks on failures
        --describe "create user errors" . before (setupTestBackend RunA3)
        --                              . after teardownTestBackend $
        --    it "rejects users with short passwords" $
        --        \ bts@(BTS _ (ActionState (_, _, _)) _ _ _) -> runTestBackend bts $ do
        --
        --            let rq1 = mkUserJson "Anna Müller" "anna@example.org" "short"
        --            rsp1 <- srequest $ makeSRequest "POST" "/principals/users" [] $ rq1
        --            liftIO $ C.statusCode (simpleStatus rsp1) `shouldBe` 400
        --            liftIO $ simpleBody rsp1 `shouldBe` "..."

        describe "send email" . before (setupTestBackend RunA3) . after teardownTestBackend $ do
            it "works" $
                \ _ -> pendingWith "test missing."

        describe "login" . before (setupTestBackend RunA3) . after teardownTestBackend $
            it "works" $
                \ _ -> pendingWith "test missing."

                -- (we need to close the previous session, probably
                -- just by direct access to DB api because the a3 rest
                -- api does not offer logout.)

-- | Create a JSON object describing an user.
-- Aeson.encode would strip the password, hence we do it by hand.
mkUserJson :: ST -> ST -> ST -> LBS
mkUserJson name email password = encodePretty . object $
  [ "data" .= object
      [ "adhocracy_core.sheets.principal.IUserBasic" .= object
          [ "name" ..= name
          ]
       , "adhocracy_core.sheets.principal.IUserExtended" .= object
          [ "email" ..= email
          ]
       , "adhocracy_core.sheets.principal.IPasswordAuthentication" .= object
          [ "password" ..= password
          ]
      ]
  , "content_type" ..= "adhocracy_core.resources.principal.IUser"
  ]


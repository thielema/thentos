{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Thentos.TransactionSpec (spec) where

import Control.Applicative ((<$>))
import Data.Monoid (mempty)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.String.Conversions (ST, SBS)
import Database.PostgreSQL.Simple (Only(..), query)
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Test.Hspec (Spec, SpecWith, describe, it, shouldBe, shouldReturn, before)

import Thentos.Action.Core
import Thentos.Transaction
import Thentos.Transaction.Core
import Thentos.Types

import Thentos.Test.Core
import Thentos.Test.Config

spec :: Spec
spec = describe "Thentos.Transaction" . before (createActionState thentosTestConfig) $ do
    addUserPrimSpec
    addUserSpec
    addUnconfirmedUserWithIdSpec
    lookupUserByNameSpec
    lookupUserByEmailSpec
    deleteUserSpec

addUserPrimSpec :: SpecWith ActionState
addUserPrimSpec = describe "addUserPrim" $ do

    it "adds a user to the database" $ \ (ActionState (conn, _, _)) -> do
        let user   = testUsers !! 2
            userId = UserId 289
        void $ runThentosQuery conn $ addUserPrim userId user
        Right (_, res) <- runThentosQuery conn $ lookupUser userId
        liftIO $ res `shouldBe` user

    it "fails if the id is not unique" $ \ (ActionState (conn, _, _)) -> do
        let userId = UserId 289
        void $ runThentosQuery conn $ addUserPrim userId (testUsers !! 2)
        x <- runThentosQuery conn $ addUserPrim userId (testUsers !! 3)
        x `shouldBe` Left UserIdAlreadyExists

    it "fails if the username is not unique" $ \ (ActionState (conn, _, _)) -> do
        let user1 = mkUser "name" "pass1" "email1@email.com"
            user2 = mkUser "name" "pass2" "email2@email.com"
        void $ runThentosQuery conn $ addUserPrim (UserId 372) user1
        x <- runThentosQuery conn $ addUserPrim (UserId 482) user2
        x `shouldBe` Left UserNameAlreadyExists

    it "fails if the email is not unique" $  \ (ActionState (conn, _, _)) -> do
        let user1 = mkUser "name1" "pass1" "email@email.com"
            user2 = mkUser "name2" "pass2" "email@email.com"
        void $ runThentosQuery conn $ addUserPrim (UserId 372) user1
        x <- runThentosQuery conn $ addUserPrim (UserId 482) user2
        x `shouldBe` Left UserEmailAlreadyExists

addUserSpec :: SpecWith ActionState
addUserSpec = describe "addUser" $ do

    it "adds a user to the database" $ \ (ActionState (conn, _, _)) -> do
        void $ runThentosQuery conn $ mapM_ addUser testUsers
        let names = _userName <$> testUsers
        Right res <- runThentosQuery conn $ mapM lookupUserByName names
        liftIO $ (snd <$> res) `shouldBe` testUsers

addUnconfirmedUserWithIdSpec :: SpecWith ActionState
addUnconfirmedUserWithIdSpec = describe "addUnconfirmedUserWithId" $ do
    let user   = mkUser "name" "pass" "email@email.com"
        userid = UserId 321
        token  = "sometoken"

    it "adds an unconfirmed user to the DB" $ \ (ActionState (conn, _, _)) -> do
        Right () <- runThentosQuery conn $ addUnconfirmedUserWithId token user userid
        Right res <- runThentosQuery conn $ lookupUserByName "name"
        liftIO $ snd res `shouldBe` user

    it "adds the token for the user to the DB" $ \ (ActionState (conn, _, _)) -> do
        Right () <- runThentosQuery conn $ addUnconfirmedUserWithId token user userid
        [res] <- query conn [sql|
            SELECT token FROM user_confirmation_tokens
            WHERE id = ? |] (Only userid)
        liftIO $ res `shouldBe` token

    it "fails if the token is not unique" $ \ (ActionState (conn, _, _)) -> do
        let user2 = mkUser "name2" "pass" "email2@email.com"
            userid2 = UserId 322
        Right () <- runThentosQuery conn $ addUnconfirmedUserWithId token user userid
        Left err <- runThentosQuery conn $ addUnconfirmedUserWithId token user2 userid2
        err `shouldBe` ConfirmationTokenAlreadyExists


lookupUserByNameSpec :: SpecWith ActionState
lookupUserByNameSpec = describe "lookupUserByName" $ do

    it "returns a user if one exists" $ \ (ActionState (conn, _, _)) -> do
        let user = mkUser "name" "pass" "email@email.com"
            userid = UserId 437
        void $ runThentosQuery conn $ addUserPrim userid user
        runThentosQuery conn (lookupUserByName "name") `shouldReturn` Right (userid, user)

    it "returns NoSuchUser if no user has the name" $ \ (ActionState (conn, _, _)) -> do
        runThentosQuery conn (lookupUserByName "name") `shouldReturn` Left NoSuchUser

lookupUserByEmailSpec :: SpecWith ActionState
lookupUserByEmailSpec = describe "lookupUserByEmail" $ do

    it "returns a user if one exists" $ \ (ActionState (conn, _, _)) -> do
        let user = mkUser "name" "pass" "email@email.com"
            userid = UserId 437
        void $ runThentosQuery conn $ addUserPrim userid user
        runThentosQuery conn (lookupUserByEmail $ forceUserEmail "email@email.com")
            `shouldReturn` Right (userid, user)

    it "returns NoSuchUser if no user has the email" $ \ (ActionState (conn, _, _)) -> do
        runThentosQuery conn (lookupUserByName "name") `shouldReturn` Left NoSuchUser

deleteUserSpec :: SpecWith ActionState
deleteUserSpec = describe "deleteUser" $ do

    it "deletes a user" $ \ (ActionState (conn, _, _)) -> do
        let user = mkUser "name" "pass" "email@email.com"
            userid = UserId 371
        void $ runThentosQuery conn $ addUserPrim userid user
        Right _  <- runThentosQuery conn $ lookupUser userid
        Right () <- runThentosQuery conn $ deleteUser userid
        runThentosQuery conn (lookupUser userid) `shouldReturn` Left NoSuchUser

    it "throws NoSuchUser if the id does not exist" $ \ (ActionState (conn, _, _)) -> do
        runThentosQuery conn (deleteUser $ UserId 210) `shouldReturn` Left NoSuchUser


-- * Utils


mkUser :: UserName -> SBS -> ST -> User
mkUser name pass email = User { _userName = name
                              , _userPassword = encryptTestSecret pass
                              , _userEmail = forceUserEmail email
                              , _userThentosSessions = mempty
                              , _userServices = mempty
                              }

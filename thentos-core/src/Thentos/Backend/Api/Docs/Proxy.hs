{-# LANGUAGE DataKinds                                #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE TypeOperators                            #-}

{-# OPTIONS -fno-warn-orphans #-}

module Thentos.Backend.Api.Docs.Proxy where

import Control.Lens ((&), (%~))
import Data.Proxy (Proxy(Proxy))
import Servant.API ((:<|>))
import Servant.Docs (HasDocs(..))

import qualified Servant.Docs as Docs
import qualified Servant.Foreign as Foreign

import Thentos.Backend.Api.Docs.Common ()
import Thentos.Backend.Api.Proxy (ServiceProxy)


instance HasDocs sublayout => HasDocs (sublayout :<|> ServiceProxy) where
    docsFor proxy dat opt = docsFor (altProxy proxy) dat opt
                        & Docs.apiIntros %~ (++ intros)
      where
        intros = [Docs.DocIntro "@@1.3@@Authenticating Proxy" [unlines desc]]
        desc = [ "All requests that are not handled by the endpoints listed"
               , "below are handled as follows:"
               , "We extract the Thentos Session Token (X-Thentos-Session) from"
               , "the request headers and forward the request to the service, adding"
               , "X-Thentos-User and X-Thentos-Groups with the appropriate"
               , "data to the request headers. If the request does not include"
               , "a valid session token, it is rejected. Responses from the"
               , "service are returned unmodified."
               ]

instance Foreign.HasForeign ServiceProxy where
    type Foreign ServiceProxy = Foreign.Req
    foreignFor Proxy req =
        req & Foreign.funcName  %~ ("ServiceProxy" :)

-- ToDo: should be part of Servant
altProxy :: Proxy (sublayout :<|> ServiceProxy) -> Proxy sublayout
altProxy Proxy = Proxy

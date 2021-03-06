module Register where

import Control.Monad.Aff (Aff(), Canceler(), runAff, forkAff, later')
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff (Eff())
import Control.Monad.Eff.Exception (throwException)
import Data.Functor (($>))
import Data.Generic
import Data.List
import Data.Tuple
import Data.Void
import Halogen (Component(), ComponentHTML(), ComponentDSL(), HalogenEffects(), Action(), Natural(), runUI, component, modify)
import Halogen.Util (appendTo)
import Prelude

import qualified Data.Array as Array
import qualified Halogen.HTML.Core as H
import qualified Halogen.HTML.Events.Handler as EH
import qualified Halogen.HTML.Events.Indexed as E
import qualified Halogen.HTML.Events.Types as ET
import qualified Halogen.HTML.Indexed as H
import qualified Halogen.HTML.Properties.Indexed as P

import Error
import Mula

foreign import onChangeValue :: forall a. a -> String


-- * types

type State =
    { stErrors        :: Array String
    , stLoggedIn      :: Boolean
    , stRegSuccess    :: Boolean
    , stName          :: String
    , stEmail         :: String
    , stPass1         :: String
    , stPass2         :: String
    , stTermsAndConds :: Boolean
    , stSupportEmail  :: String  -- FIXME: use newtype and smart constructor

    -- TODO: trigger for update loop of surrounding framework.

    }

initialState :: State
initialState =
    { stErrors: []
    , stLoggedIn: false
    , stRegSuccess: false
    , stName: ""
    , stEmail: ""
    , stPass1: ""
    , stPass2: ""
    , stTermsAndConds: false
    , stSupportEmail: ""
    }

data Query a =
    KeyPressed (State -> State) a
  | UpdateTermsAndConds Boolean a


-- * render

render :: State -> ComponentHTML Query
render st = H.div [cl "login"]
    [ mydebug st
    , body st
    , H.a [cl "login-cancel", P.href ""]  -- FIXME: link!
        [translate "TR__CANCEL"]
    , H.div [cl "login-info"]
        [ translate "TR__REGISTRATION_SUPPORT"
        , H.br_
        , H.a [P.href $ "mailto:" ++ st.stSupportEmail ++ "?subject=Trouble%20with%20registration"]
            [H.text st.stSupportEmail]
        ]
    ]

body :: State -> ComponentHTML Query
body st = case Tuple st.stLoggedIn st.stRegSuccess of

    -- present empty or incomplete registration form
    Tuple false false -> H.form [cl "login-form", P.name "registerForm"] $
        [H.div_ $ errors st] ++
        [ inputField P.InputText (translate "TR__USERNAME") "username"
            (\i s -> s { stName = i })
        , inputField P.InputEmail (translate "TR__EMAIL") "email"
            (\i s -> s { stEmail = i })
        , inputField P.InputPassword (translate "TR__PASSWORD") "password"
            (\i s -> s { stPass1 = i })
        , inputField P.InputPassword (translate "TR__PASSWORD_REPEAT") "password_repeat"
            (\i s -> s { stPass2 = i })

        , H.label [cl "login-check"]
            [ H.div [cl "login-check-input"]
                [ H.input [ P.inputType P.InputCheckbox, P.name "registerCheck", P.required true
                          , E.onChecked $ E.input $ UpdateTermsAndConds
                          ]
                , H.span_ [translate "TR__I_ACCEPT_THE_TERMS_AND_CONDITIONS"]  -- FIXME: link!
                ]
            ]

        , H.input
            [ P.inputType P.InputSubmit, P.name "register", P.value (translateS "TR__REGISTER")
            , P.disabled $ not $ Data.Array.null st.stErrors
            , E.onChecked $ E.input $ UpdateTermsAndConds
            ]
        , H.div [cl "login-info"] [H.p_ [translate "TR__REGISTRATION_LOGIN_INSTEAD"]]  -- FIXME: link!
        ]

    -- can not register: already logged in
    Tuple false true -> H.div [cl "login-success"] [H.p_ [translate "TR__REGISTRATION_ALREADY_LOGGED_IN"]]

    -- registered: waiting for processing of activation email
    Tuple true false -> H.div [cl "login-success"]
        [ H.h2_ [translate "TR__REGISTER_SUCCESS"]
        , H.p_ [translate "TR__REGISTRATION_CALL_FOR_ACTIVATION"]

        -- FIXME: the a3 code says this.  what does it mean?:
        -- 'Show option in case the user is not automatically logged in (e.g. 3rd party cookies blocked.)'
        ]

    -- FIXME: a3 code says this.  is that relevant for us?
    -- <!-- FIXME: Technically this should only display if you logged in as the user you just registered as, but
    -- this will display if you log in as any user -->

    -- registered and registration link clicked
    Tuple true true -> H.div [cl "login-success"]
        [ H.h2_ [translate "TR__REGISTRATION_THANKS_FOR_REGISTERING"]
        , H.p_ [translate "TR__REGISTRATION_PROCEED"]  -- FIXME: link
        ]


mydebug :: State -> ComponentHTML Query
mydebug st = H.pre_
    [ H.p_ [H.text $ show st.stErrors]
    , H.p_ [H.text $ show st.stLoggedIn]
    , H.p_ [H.text $ show st.stRegSuccess]
    , H.p_ [H.text $ show st.stName]
    , H.p_ [H.text $ show st.stEmail]
    , H.p_ [H.text $ show st.stPass1]
    , H.p_ [H.text $ show st.stPass2]
    , H.p_ [H.text $ show st.stTermsAndConds]
    ]

errors :: State -> Array (ComponentHTML Query)
errors st = f <$> st.stErrors
  where
    f :: String -> ComponentHTML Query
    f msg = H.div [cl "form-error"] [H.p_ [translate msg]]

inputField :: P.InputType -> ComponentHTML Query -> String
           -> (String -> State -> State)
           -> ComponentHTML Query
inputField inputType msg key updateState = H.label_
    [ H.span [cl "label-text"] [msg]
    , H.input [ P.inputType inputType, P.name key, P.required true
              , E.onInput $ E.input $ KeyPressed <<< updateState <<< onChangeValue
              ]
    ]

-- there is something about this very similar to `translate`: we want to be able to collect all
-- classnames occurring in a piece of code, and construct a list from them with documentation
-- (source file locations?).
cl :: forall r i. String -> P.IProp (class :: P.I | r) i
cl = P.class_ <<< H.className


-- * eval

eval :: forall g. Natural Query (ComponentDSL State Query g)
eval (KeyPressed updateState next) = do
    modify updateState
    modify checkState
    pure next
eval (UpdateTermsAndConds newVal next) = do
    modify (\st -> st { stTermsAndConds = newVal })
    modify checkState
    pure next

checkState :: State -> State
checkState st = st { stErrors = passwordMismatch ++ invalidEmail }
  where
    passwordMismatch :: Array String
    passwordMismatch = if st.stPass1 == st.stPass2 then [] else ["passwords must match"]

    invalidEmail :: Array String
    invalidEmail = if st.stEmail /= "invalid" then [] else ["invalid email"]

    -- FIXME: translation keys for errors?
    -- FIXME: which other errors are there?


-- * main

ui :: forall g. (Functor g) => Component State Query g
ui = component render eval

main :: forall eff. String -> Eff (HalogenEffects eff) Unit
main selector = runAff throwException (const (pure unit)) <<< forkAff $ do
    { node: node, driver: driver } <- runUI ui initialState
    appendTo selector node


-- FIXME: widget destruction?

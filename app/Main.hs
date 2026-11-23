{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The whole application logic of the time tracker lives here.  JavaScript is
-- only a host: it loads this module as a WebAssembly reactor, forwards DOM
-- events to 'hsOnAction' and offers a handful of small DOM/IndexedDB helpers
-- through the JavaScript FFI.
module Main (main) where

import Control.Exception (SomeException, catch, evaluate)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find, intercalate, sortBy)
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (comparing)
import GHC.Wasm.Prim (JSString (..), JSVal, fromJSString, toJSString)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)

--------------------------------------------------------------------------------
-- Foreign imports: browser helpers defined in web/helpers.js
--------------------------------------------------------------------------------

foreign import javascript unsafe "globalThis.TT.now()"
  jsNow :: IO Double

foreign import javascript unsafe "globalThis.TT.uuid()"
  jsUuid :: IO JSString

foreign import javascript unsafe "globalThis.TT.today()"
  jsToday :: IO JSString

foreign import javascript unsafe "globalThis.TT.shiftDay($1,$2)"
  jsShiftDay :: JSString -> Int -> IO JSString

foreign import javascript unsafe "globalThis.TT.timeOf($1)"
  jsTimeOf :: Double -> IO JSString

foreign import javascript unsafe "globalThis.TT.hhmm($1)"
  jsHhmm :: Double -> IO JSString

foreign import javascript unsafe "globalThis.TT.vibrate()"
  jsVibrate :: IO ()

foreign import javascript unsafe "globalThis.TT.setText($1,$2)"
  jsSetText :: JSString -> JSString -> IO ()

foreign import javascript unsafe "globalThis.TT.clear($1)"
  jsClear :: JSString -> IO ()

foreign import javascript unsafe "globalThis.TT.show($1,$2)"
  jsShow :: JSString -> Int -> IO ()

foreign import javascript unsafe "globalThis.TT.active($1,$2)"
  jsActive :: JSString -> Int -> IO ()

foreign import javascript unsafe "globalThis.TT.tile($1,$2,$3,$4,$5)"
  jsTile :: JSString -> JSString -> JSString -> JSString -> JSString -> IO JSVal

foreign import javascript unsafe "globalThis.TT.append($1,$2)"
  jsAppend :: JSString -> JSVal -> IO ()

foreign import javascript unsafe "globalThis.TT.row($1,$2,$3,$4,$5,$6)"
  jsRow :: JSString -> JSString -> JSString -> JSString -> JSString -> Int -> IO JSVal

foreign import javascript unsafe "globalThis.TT.getValue($1)"
  jsGetValue :: JSString -> IO JSString

foreign import javascript unsafe "globalThis.TT.setValue($1,$2)"
  jsSetValue :: JSString -> JSString -> IO ()

foreign import javascript safe "globalThis.TT.idbOpen()"
  jsIdbOpen :: IO JSString

foreign import javascript safe "globalThis.TT.idbAll()"
  jsIdbAll :: IO JSVal

foreign import javascript safe "globalThis.TT.idbPut($1,$2,$3,$4)"
  jsIdbPut :: JSString -> JSString -> Double -> JSString -> IO JSString

foreign import javascript safe "globalThis.TT.idbDelete($1)"
  jsIdbDelete :: JSString -> IO JSString

foreign import javascript safe "globalThis.TT.confirm($1)"
  jsConfirm :: JSString -> IO Bool

foreign import javascript unsafe "globalThis.TT.download($1,$2)"
  jsDownload :: JSString -> JSString -> IO ()

foreign import javascript unsafe "$1.length"
  jsLen :: JSVal -> Int

foreign import javascript unsafe "$1[$2].id"
  jsRecId :: JSVal -> Int -> IO JSString

foreign import javascript unsafe "$1[$2].icon"
  jsRecIcon :: JSVal -> Int -> IO JSString

foreign import javascript unsafe "$1[$2].ts"
  jsRecTs :: JSVal -> Int -> IO Double

foreign import javascript unsafe "$1[$2].label"
  jsRecLabel :: JSVal -> Int -> IO JSString

foreign import javascript unsafe "$1[$2].date"
  jsRecDate :: JSVal -> Int -> IO JSString

-- Force the result of an asynchronous JSFFI import (a Promise-backed thunk).
force :: IO a -> IO a
force act = do
  x <- act
  _ <- evaluate x
  pure x

t :: String -> JSString
t = toJSString

--------------------------------------------------------------------------------
-- Model
--------------------------------------------------------------------------------

data Entry = Entry
  { eId    :: String
  , eIcon  :: String
  , eTs    :: Double       -- milliseconds since the Unix epoch
  , eLabel :: String
  , eDate  :: String       -- local YYYY-MM-DD, cached in IndexedDB
  } deriving (Show)

data AppState = AppState
  { sEntries  :: [Entry]
  , sDay      :: String
  , sScreen   :: String    -- "tap" or "day"
  , sDraft    :: String    -- initial value shown in the native text field
  , sEditId   :: Maybe String
  , sKbOpen   :: Bool
  , sLast     :: String
  }

initialState :: AppState
initialState = AppState [] "" "tap" "" Nothing False "Ready"

{-# NOINLINE appRef #-}
appRef :: IORef AppState
appRef = unsafePerformIO (newIORef initialState)

-- (key, glyph, label).  These are the 16 always-available logging icons.
icons :: [(String, String, String)]
icons =
  [ ("eat",         "🍽", "Eat")
  , ("dishes",      "🧽", "Dishes")
  , ("clean",       "🧹", "Clean")
  , ("call",        "📞", "Call")
  , ("socialize",   "👥", "Socialize")
  , ("read",        "📖", "Read")
  , ("coding",      "💻", "Coding")
  , ("sleep",       "😴", "Sleep")
  , ("plan",        "🗓", "Plan")
  , ("journal",     "📔", "Journal")
  , ("socials",     "📱", "Check socials")
  , ("dailies",     "✅", "Dailies")
  , ("laundry",     "🧺", "Laundry")
  , ("fold",        "👕", "Fold clothes")
  , ("blog",        "✍", "Write blog post")
  , ("shower",      "🚿", "Shower")
  ]

--------------------------------------------------------------------------------
-- Exported entry points
--------------------------------------------------------------------------------

foreign export javascript "start" hsStart :: IO ()
foreign export javascript "onAction" hsOnAction :: JSString -> JSString -> IO ()

hsStart :: IO ()
hsStart = guarded $ do
  _ <- force jsIdbOpen
  today <- fromJSString <$> force jsToday
  entries <- loadEntries
  modifyIORef' appRef (\s -> s { sEntries = entries, sDay = today })
  render

hsOnAction :: JSString -> JSString -> IO ()
hsOnAction action payload = guarded $
  handle (fromJSString action) (fromJSString payload)

guarded :: IO () -> IO ()
guarded action = action `catch` \(e :: SomeException) ->
  status ("Error: " ++ show e)

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

loadEntries :: IO [Entry]
loadEntries = do
  arr <- force jsIdbAll
  let n = jsLen arr
  mapM (readRecord arr) [0 .. n - 1]

readRecord :: JSVal -> Int -> IO Entry
readRecord arr i = do
  ident <- fromJSString <$> force (jsRecId arr i)
  icon  <- fromJSString <$> force (jsRecIcon arr i)
  ts    <- force (jsRecTs arr i)
  label <- fromJSString <$> force (jsRecLabel arr i)
  date  <- fromJSString <$> force (jsRecDate arr i)
  pure Entry { eId = ident, eIcon = icon, eTs = ts, eLabel = label, eDate = date }

persist :: Entry -> IO ()
persist e =
  voidString (jsIdbPut (t (eId e)) (t (eIcon e)) (eTs e) (t (eLabel e)))

remove :: String -> IO ()
remove ident = voidString (jsIdbDelete (t ident))

voidString :: IO JSString -> IO ()
voidString action = do
  _ <- force action
  pure ()

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

handle :: String -> String -> IO ()
handle "icon" key =
  case find (\(k, _, _) -> k == key) icons of
    Nothing -> status "Unknown icon"
    Just (_, glyph, label) -> do
      ts <- jsNow
      ident <- fromJSString <$> force jsUuid
      day <- fromJSString <$> force (jsDateOf ts)
      let entry = Entry ident key ts (glyph ++ " " ++ label) day
      _ <- force (jsIdbPut (t ident) (t key) ts (t (eLabel entry)))
      jsVibrate
      clock <- fromJSString <$> jsTimeOf ts
      modifyIORef' appRef $ \s -> s
        { sEntries = entry : sEntries s
        , sLast = label ++ " logged at " ++ clock
        }
      render

handle "type" _ = do
  modifyIORef' appRef $ \s -> s
    { sKbOpen = True, sDraft = "", sEditId = Nothing }
  render

handle "edit" ident = do
  s <- readIORef appRef
  case find ((== ident) . eId) (sEntries s) of
    Nothing -> status "Entry not found"
    Just entry -> do
      hhmm <- fromJSString <$> jsHhmm (eTs entry)
      jsSetValue (t "edit-time") (t hhmm)
      modifyIORef' appRef $ \st -> st
        { sKbOpen = True, sDraft = eLabel entry, sEditId = Just ident }
      render

handle "cancel" _ = do
  modifyIORef' appRef (\s -> s { sKbOpen = False, sEditId = Nothing, sDraft = "" })
  render

handle "save" _ = do
  -- The native keyboard owns the text field; read whatever the user typed.
  typed <- fromJSString <$> force (jsGetValue (t "kb-text"))
  s <- readIORef appRef
  let draft = trim typed
  if null draft
    then status "Type something first"
    else case sEditId s of
      Nothing -> do
        ts <- jsNow
        ident <- fromJSString <$> force jsUuid
        day <- fromJSString <$> force (jsDateOf ts)
        let entry = Entry ident "custom" ts draft day
        persist entry
        clock <- fromJSString <$> jsTimeOf ts
        modifyIORef' appRef $ \st -> st
          { sEntries = entry : sEntries st
          , sKbOpen = False, sDraft = "", sLast = "Note logged at " ++ clock
          }
        render
      Just ident -> do
        case find ((== ident) . eId) (sEntries s) of
          Nothing -> status "Entry not found"
          Just old -> do
            timeValue <- fromJSString <$> force (jsGetValue (t "edit-time"))
            ts <- if null timeValue
              then pure (eTs old)
              else force (jsParseTime (t (sDay s)) (t timeValue))
            newDay <- fromJSString <$> jsDateOf ts
            let updated = old { eLabel = draft, eTs = ts, eDate = newDay }
            persist updated
            clock <- fromJSString <$> jsTimeOf ts
            modifyIORef' appRef $ \st -> st
              { sEntries = map (\e -> if eId e == ident then updated else e) (sEntries st)
              , sDay = newDay, sKbOpen = False, sEditId = Nothing, sDraft = ""
              , sLast = "Entry updated at " ++ clock
              }
            render

handle "delete" ident = do
  ok <- force (jsConfirm (t "Delete this entry?"))
  if not ok then pure () else do
    remove ident
    modifyIORef' appRef $ \s -> s
      { sEntries = filter ((/= ident) . eId) (sEntries s)
      , sKbOpen = False, sEditId = Nothing, sLast = "Entry deleted"
      }
    render

handle "screen" name = do
  modifyIORef' appRef (\s -> s { sScreen = name })
  render

handle "dayPrev" _ = shiftDay (-1)
handle "dayNext" _ = shiftDay 1

handle "dayToday" _ = do
  today <- fromJSString <$> force jsToday
  modifyIORef' appRef (\s -> s { sDay = today })
  render

handle "export" _ = do
  s <- readIORef appRef
  let rows = sortBy (comparing eTs) (sEntries s)
      header = "timestamp,date,time,icon,label"
      line e clock = intercalate ","
        [ csv (show (round (eTs e) :: Integer))
        , csv (eDate e)
        , csv clock
        , csv (eIcon e)
        , csv (eLabel e)
        ]
      csv v = "\"" ++ concatMap (\c -> if c == '"' then "\"\"" else [c]) v ++ "\""
  rendered <- mapM (\e -> do
      clock <- fromJSString <$> jsTimeOf (eTs e)
      pure (line e clock)) rows
  jsDownload (t "time-tracking.csv") (t (unlines (header : rendered)))
  status "CSV exported"

handle action _ = status ("Unknown action: " ++ action)

shiftDay :: Int -> IO ()
shiftDay n = do
  s <- readIORef appRef
  next <- fromJSString <$> force (jsShiftDay (t (sDay s)) n)
  modifyIORef' appRef (\st -> st { sDay = next })
  render

status :: String -> IO ()
status = jsSetText (t "app-status") . t

trim :: String -> String
trim = dropWhileEnd' (== ' ') . dropWhile (== ' ')
  where
    dropWhileEnd' p = reverse . dropWhile p . reverse

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

render :: IO ()
render = do
  s <- readIORef appRef
  let isTap = sScreen s == "tap"
  jsShow (t "screen-tap") (if isTap then 1 else 0)
  jsShow (t "screen-day") (if isTap then 0 else 1)
  jsShow (t "keyboard-overlay") (if sKbOpen s then 1 else 0)
  jsActive (t "nav-tap") (if isTap then 1 else 0)
  jsActive (t "nav-day") (if isTap then 0 else 1)
  jsSetText (t "selected-day") (t (sDay s))
  jsSetText (t "last-logged") (t (sLast s))
  renderGrid
  renderDay s
  renderKeyboard s

renderGrid :: IO ()
renderGrid = do
  jsClear (t "icon-grid")
  mapM_ addIcon icons
  tile <- jsTile (t "⌨") (t "Type exact activity") (t "type") (t "") (t "wide")
  jsAppend (t "icon-grid") tile
  where
    addIcon (key, glyph, label) = do
      node <- jsTile (t glyph) (t label) (t "icon") (t key) (t "")
      jsAppend (t "icon-grid") node

renderDay :: AppState -> IO ()
renderDay s = do
  jsClear (t "entry-list")
  let todays = filter ((== sDay s) . eDate) (sEntries s)
      ordered = sortBy (flip (comparing eTs)) todays
      ascending = reverse ordered
  jsSetText (t "day-count") (t (show (length todays) ++ " entries"))
  mapM_ (addRow ascending) (zip [0 ..] ordered)
  if null ordered
    then status' "Nothing logged on this day yet"
    else status' (show (length todays) ++ " entries on this day")
  where
    status' = jsSetText (t "day-hint") . t
    addRow ascending (idx, entry) = do
      clock <- fromJSString <$> jsTimeOf (eTs entry)
      let (_, glyph, _) = fromMaybe ("", "", "") (find (\(k, _, _) -> k == eIcon entry) icons)
          duration = durationAfter ascending idx
      node <- jsRow (t (eId entry)) (t clock) (t (if null glyph then "✏️" else glyph))
                    (t (eLabel entry)) (t duration)
                    (if sEditId s == Just (eId entry) then 1 else 0)
      jsAppend (t "entry-list") node

-- Each entry marks the start of an activity; show how long until the next one.
durationAfter :: [Entry] -> Int -> String
durationAfter ascending descendingIndex =
  let ascIndex = length ascending - 1 - descendingIndex
  in if ascIndex < 0 || ascIndex >= length ascending - 1
       then "latest"
       else let gap = eTs (ascending !! (ascIndex + 1)) - eTs (ascending !! ascIndex)
            in "for " ++ formatGap gap

formatGap :: Double -> String
formatGap ms
  | minutes < 1 = "<1m"
  | minutes < 60 = show minutes ++ "m"
  | otherwise = show (minutes `div` 60) ++ "h " ++ show (minutes `mod` 60) ++ "m"
  where
    minutes = max 0 (round (ms / 60000) :: Int)

renderKeyboard :: AppState -> IO ()
renderKeyboard s = do
  -- Only seed the field when the dialog opens; while it is open the native
  -- keyboard and the DOM are the source of truth.
  jsSetValue (t "kb-text") (t (sDraft s))
  jsShow (t "edit-time-row") (if isJust (sEditId s) then 1 else 0)
  jsSetText (t "kb-save") (t (if isJust (sEditId s) then "Save changes" else "Log entry"))
  jsSetText (t "kb-title")
    (t (if isJust (sEditId s) then "Edit entry" else "Exact activity"))

foreign import javascript unsafe "globalThis.TT.parseTime($1,$2)"
  jsParseTime :: JSString -> JSString -> IO Double

foreign import javascript unsafe "globalThis.TT.dateOf($1)"
  jsDateOf :: Double -> IO JSString

main :: IO ()
main = pure ()

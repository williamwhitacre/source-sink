module Flow.Sequence
  ( Counter
  , Behavior(..)

  , counter
  , behavior

  , monotonic
  , user

  , step
  , steps
  , reset

  , value
  ) where

{-| This module provides an opaque type for counters that is less ambiguous about it's purpose than
a plain integer would be with a nice, clean API.

# Types
@docs Counter, Behavior

# Construction by Tag
@docs counter, behavior

# Direct Construction
@docs monotonic, user

# Control
@docs step, steps, reset

# Inquire
@docs value
-}


import Debug


{-| A counter. -}
type Counter =
  SeqMono Int
  | SeqUser (Int -> Int -> Int) Int


{-| A tag representing the behavior of the given counter. -}
type Behavior =
  Monotonic
  | User (Int -> Int -> Int)


{-| Create a new counter that monotonically increases it's value by one with each step. -}
monotonic : Counter
monotonic =
  SeqMono 0


{-| Create a counter which advances by a user defined function `Int -> Int -> Int`, where the first
argument is the number of steps and the second is the previous value of the counter. -}
user : (Int -> Int -> Int) -> Counter
user f =
  SeqUser f 0


{-| Create a counter with the specified behavior. -}
counter : Behavior -> Counter
counter behavior =
  case behavior of
    Monotonic -> monotonic
    User f -> user f


{-| Inquire about the behavior configured . -}
behavior : Counter -> Behavior
behavior seq =
  case seq of
    SeqMono _ -> Monotonic
    SeqUser f _ -> User f


{-| Advance a counter by one step.

    step = steps 1

-}
step : Counter -> Counter
step =
  steps 1


{-| Advance a counter by the given number of steps. A negative input is not allowed and will
cause a crash.
-}
steps : Int -> Counter -> Counter
steps count seq =
  if count >= 0 then
    case seq of
      SeqMono i -> SeqMono (i + count)
      SeqUser f i -> SeqUser f (f count i)
  else
    Debug.crash
      ("Invalid argument " ++ toString count ++ " to Flow.Counter.steps. "
      ++ "count must be a natural number or 0.")


{-| Reset a counter. This will always reset the given counter to it's original state. -}
reset : Counter -> Counter
reset seq =
  case seq of
    SeqMono _ -> monotonic
    SeqUser f _ -> user f


{-| Get the current value of the counter. -}
value : Counter -> Int
value seq =
  case seq of
    SeqMono i -> i
    SeqUser _ i -> i

module Flow.Transform
  ( Transform

  , xfIdentity
  , xfValue
  , xfPair

  , append
  , prepend
  , pipeline
  , pipelineR

  , apply
  ) where

{-|

# Transform Type
@docs Transform

# Transform Primitives
@docs xfIdentity, xfValue, xfPair

# Composition
@docs append, prepend, pipeline, pipelineR

# Low Level
@docs apply

-}

import Trampoline exposing (..)
import Lazy exposing (Lazy)
import List


{-| -}
type Transform a b =
  Transform
    { func : Lazy ( ((String, Int), Maybe a) -> Maybe ((String, Int), Maybe b) )
    }


{-| -}
xfIdentity : Transform doc doc
xfIdentity =
  Transform
    { func = Lazy.lazy (\() -> identity >> Just)
    }


{-| -}
xfValue : (String -> Maybe a -> Maybe b) -> Transform a b
xfValue fvalue =
  xfPair (\key json -> Just (key, fvalue key json))


{-| -}
xfPair : (String -> Maybe a -> Maybe (String, Maybe b)) -> Transform a b
xfPair f =
  Transform
    { func = Lazy.lazy
        (\() ->
          \((ref, seqno), json) ->
            f ref json
            |> Maybe.map (\(ref', json') -> ((ref', seqno), json'))
        )
    }


{-| -}
append : Transform b c -> Transform a b -> Transform a c
append (Transform ta) (Transform tb) =
  Transform
    { func = Lazy.map2
        (\fa fb -> fb     -- fb and fa are switched in prepend
          >> Maybe.map fa
          >> Maybe.withDefault Nothing
        ) ta.func tb.func
    }


{-| -}
prepend : Transform a b -> Transform b c -> Transform a c
prepend (Transform ta) (Transform tb) =
  Transform
    { func = Lazy.map2
        (\fa fb -> fa     -- fa and fb are switched in append
          >> Maybe.map fb
          >> Maybe.withDefault Nothing
        ) ta.func tb.func
    }


{-| -}
pipeline : List (Transform doc doc) -> Transform doc doc
pipeline =
  pipelineImpl False


{-| -}
pipelineR : List (Transform doc doc) -> Transform doc doc
pipelineR =
  pipelineImpl True


pipelineImpl : Bool -> List (Transform doc doc) -> Transform doc doc
pipelineImpl reversed_ list =
  case list of
    [] -> xfIdentity
    xform :: listTail -> trampoline (pipeline' reversed_ xform listTail)



pipeline' : Bool -> Transform doc doc -> List (Transform doc doc) -> Trampoline (Transform doc doc)
pipeline' reversed_ accum list' =
  let
    faccum_ =
      if reversed_ then prepend else append

  in
    case list' of
      [] ->
        Done accum

      xform :: listTail ->
        Continue (\() -> pipeline' reversed_ (faccum_ xform accum) listTail)


{-| Internal use. Unwrap a transform to lazily evaluate -}
apply : Transform a b -> List ((String, Int), Maybe a) -> Lazy (List ((String, Int), Maybe b))
apply (Transform xform) elements =
  Lazy.map (\f -> List.filterMap f elements) xform.func

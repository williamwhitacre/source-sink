module Flow.Internal.Image where

import Flow.Sequence as Sequence exposing (Counter, Behavior)
import Flow.Internal.Stream as Stream exposing (Factory, Pipe, Emitter)
import Flow.Transform as XF exposing (Transform)


type Range tindex trange toutput =
  Range
    { domain : Lazy (List (tindex, Maybe toutput))
    , range : trange
    }

range
  :  (trange -> stor -> List (tindex, Maybe toutput))
  -> trange -> stor
  -> Range tindex trange toutput
range f r storage =
  Range { domain = Lazy.lazy (\() -> f r storage), range = r }


domain : Range tindex trange toutput -> List (tindex, Maybe toutput)
domain (Range {domain}) =
  Lazy.force domain


input : Range tindex trange toutput -> trange
input (Range {range}) =
  range


{-| Specifies whether the given input is synchronous (a snapshot) or a delta payload. -}
type Payload =
  PayloadSnapshot
  | PayloadDelta


{-| A guide to the types:

    inp - input document type. This should be the prior type of a transform provided with
          configuration
    doc - document type
    idx - index type for the getter, setter and inquiry
    rng - this is the image implementer's range type. it should reflect their query needs.
    stor - this is the storage structure type. For example, a simple dictionary would probably use
           identity for the `index'` function and Dict.empty for `empty'`.

A guide to the members:

* `empty'` - This should be set to the empty storage structure of your choosing.
* `inquiry` - This function should produce a range from an image that can be resolved using
              `domain`. Use a partial application of `range` to obtain such a function.
* `getter` - User provided function to get the document at a given index if it exists.
* `setter` - User provided function to set a given list of index document pairs.

-}
type alias Config doc idx rng stor =
  { empty' : stor
  , inquiry : rng -> stor -> Range idx rng doc
  , getter : idx -> stor -> Maybe doc
  , setter : List (idx, Maybe doc) -> stor -> stor
  }


type Image doc stor =
  Image
    { deltas : Lazy (List ((String, Int), Maybe doc))
    , storage : Lazy stor
    , resynch : Bool
    }


clear : Config doc idx rng stor -> Image doc stor -> Image doc stor
clear conf (Image image) =
  Image
    {
    }

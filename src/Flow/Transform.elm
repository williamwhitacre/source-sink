module Flow.Transform
  ( Transform

  , identity'
  , valueTransform
  , pairTransform

  , append
  , prepend
  , pipeline
  , pipelineR

  ) where

{-|

# Transform Type
@docs Transform

# Transform Primitives
@docs identity', valueTransform, pairTransform

# Composition
@docs append, prepend, pipeline, pipelineR

-}

import Flow.Internal.Transform as Internal

{-| -}
type alias Transform a b =
  Internal.Transform a b


{-| -}
identity' : Transform doc doc
identity' = Internal.identity'


{-| -}
valueTransform : (String -> Maybe a -> Maybe b) -> Transform a b
valueTransform = Internal.valueTransform


{-| -}
pairTransform : (String -> Maybe a -> Maybe (String, Maybe b)) -> Transform a b
pairTransform = Internal.pairTransform


{-| -}
append : Transform b c -> Transform a b -> Transform a c
append = Internal.append


{-| -}
prepend : Transform a b -> Transform b c -> Transform a c
prepend = Internal.prepend


{-| -}
pipeline : List (Transform doc doc) -> Transform doc doc
pipeline = Internal.pipeline


{-| -}
pipelineR : List (Transform doc doc) -> Transform doc doc
pipelineR = Internal.pipelineR

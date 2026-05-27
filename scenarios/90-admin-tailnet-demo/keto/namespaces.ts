import { Namespace } from "@ory/keto-namespace-types"

class user implements Namespace {}

class scope implements Namespace {
  related: {
    granted: user[]
  }
}

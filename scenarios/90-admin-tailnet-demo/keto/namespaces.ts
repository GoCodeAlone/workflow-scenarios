import { Namespace } from "@ory/keto-namespace-types"

class user implements Namespace {}

class scope implements Namespace {
  related: {
    granted: user[]
  }
}

class resource implements Namespace {
  related: {
    owner: user[]
    viewer: user[]
    "delegated-admin": user[]
  }
}

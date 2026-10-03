# Ledger iOS

Ledger iOS is the mobile client of the Ledger Platform.

The app handles the user-facing payment flow, recovery after uncertain network results, account balances, statements, and session state.

## Tech Stack

- Swift
- UIKit
- Swift Concurrency
- URLSession
- Swift Testing / XCTest

## First Vertical Flow

The first feature focuses on payment reliability.

The client creates a payment intent with an idempotency key. If the result is unknown, the app keeps the same intent and checks its status before deciding whether another payment request is safe.

```text
Create payment
    |
    v
Unknown result
    |
    v
Check payment attempt
    |
    +--> succeeded
    +--> declined
    +--> processing
    +--> not found
    +--> expired
```

## Planned Structure

```text
App/

Features/
└── Payments/

Packages/
└── Payments/

Support/
└── PaymentLab/

Contracts/
└── payments/

LedgerUITests/
```

The existing payment reliability lab will be integrated as the first Payments feature. The simulated backend will remain development and test infrastructure, not production app code.

## Planned Scope

- integrate the payment reliability lab
- preserve `PaymentIntent` after an unknown result
- implement payment creation
- implement status-based recovery
- add receipt and recovery states
- keep contract tests for the payment API
- add account balance and statement flows later

## Platform

Ledger iOS is part of the Ledger Platform:

- [ledger-bff](https://github.com/swiftdecodificado/ledger-bff)
- [ledger-core](https://github.com/swiftdecodificado/ledger-core)
- [ledger-platform-roadmap](https://github.com/swiftdecodificado/ledger-platform-roadmap)

The shared architecture and delivery roadmap are maintained in the roadmap repository.

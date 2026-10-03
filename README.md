# Ledger iOS

The iOS client of the Ledger Platform.

The first feature in this repository focuses on payment reliability: making sure one payment intent does not create more than one financial effect when the network fails or the response never arrives.

The current implementation covers:

- `PaymentIntent`, which keeps the same idempotency key across retries of the same payment;
- idempotent `POST /payments` requests using the `Idempotency-Key` header;
- unknown outcomes such as timeouts, lost responses, and `5xx` errors, treated as "not confirmed" instead of "failed";
- status recovery through `GET /payment-attempts/{key}` before sending another `POST`;
- a mock backend that follows the same HTTP contract;
- contract tests that run against the mock and, optionally, against a real backend;
- failure simulation, including lost responses, crashes before commit, and failures after commit.

The mock backend is development and test infrastructure. It lets the app and test suites run without a real server. It is not production backend code.

Requirements: Xcode 16 or later, iOS 17+, Swift 6 language mode. No external dependencies.

## Ledger Platform

| Repository | Role |
| --- | --- |
| `ledger-ios` | iOS client (this repository) |
| `ledger-bff` | Backend for Frontend for mobile clients |
| `ledger-core` | Core financial backend |
| `ledger-platform-roadmap` | Platform roadmap |

## Structure

| Path | Responsibility |
| --- | --- |
| `App/` | App lifecycle and composition: `AppDelegate`, `SceneDelegate`, `AppDependencies`, and `Info.plist`. |
| `Features/Payments/UI/` | Production payment UI: `PaymentViewController` and `PaymentView`. |
| `Support/PaymentLab/` | Debug and demo UI: `LabViewController` and `MockServerPanelView`. This is not part of the production feature flow. |
| `Packages/Payments/` | Production payment code: `PaymentIntent`, `PaymentClient`, `HTTPPaymentTransport`, `PaymentStatus`, `PaymentError`, wire formats, and `PaymentsTests`. This package has no dependencies. |
| `Packages/PaymentsTestSupport/` | Development and test infrastructure: `MockPaymentHTTPServer`, `MockPaymentBackend`, `InMemoryPaymentLedger`, and `PaymentsTestSupportTests`. This package depends on `Payments`. |
| `ContractTests/` | `PaymentsContractTests`, which validate the HTTP contract against both the mock and, optionally, a real backend. Kept separate from package tests so contract coverage is not confused with unit coverage. |
| `Contracts/payments/openapi.yaml` | Payment API contract between the app and the backend, including idempotency rules. |
| `LedgerTests/` | Hosted app tests for button state, recovery, resend rules, processing state, expiration handling, new payment flows, and declines. |
| `LedgerUITests/` | UI tests for lost-response recovery, disabled-button behavior, and starting a new payment. |

The app uses the local `Payments` and `PaymentsTestSupport` packages.

`PaymentsTestSupport` is development and test infrastructure only. The app links it today because there is no real backend yet, but it does not contain production payment rules.

The dependency direction is:

```text
Payments
    ↑
PaymentsTestSupport
    ↑
ContractTests
```

`Payments` has no dependencies. `PaymentsTestSupport` depends on `Payments`, and `ContractTests` depends on both.

## Running

1. Open `Ledger.xcodeproj`.
2. Select the `Ledger` scheme.
3. Choose an iPhone simulator and run with `⌘R`.
4. Use `⌘U` to run hosted tests and UI tests.

From the terminal:

```sh
# Payments package
swift test --package-path Packages/Payments

# Payments test support
swift test --package-path Packages/PaymentsTestSupport

# Contract tests against the mock
swift test --package-path ContractTests

# App, hosted tests, and UI tests
xcodebuild \
  -project Ledger.xcodeproj \
  -scheme Ledger \
  -destination 'platform=iOS Simulator,name=iPhone 13 Pro Max' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Use a simulator that exists in your local Xcode installation.

If `xcode-select` points to Command Line Tools, prefix the command with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Mock backend

By default, the mock processes the first payment and loses the response.

The app shows:

```text
Não foi possível confirmar o pagamento
```

On the next tap, the action changes to "Verificar pagamento". The app checks the payment attempt using the same idempotency key instead of sending another `POST`.

If the server already completed the payment, the app shows the receipt.

The "Servidor simulado" panel shows:

- 1 `POST`
- 1 status check
- 1 debit in the ledger

The "Falha no próximo POST" picker controls what happens to the next payment request.

### Lose response

The server commits the debit, but the response never reaches the app.

The status lookup finds the payment later.

### Crash before commit

The server reserves the idempotency key and stops before creating a financial effect.

The status lookup returns `processing` until the reservation expires. After that, recovery may send the same `POST` again with the same key.

### Launch arguments

Use Product → Scheme → Edit Scheme → Arguments.

Available options:

```text
-MockFirstFault none | loseResponse | crashBeforeCommit | failAfterCommit
```

Default:

```text
loseResponse
```

Network and processing delay:

```text
-MockDelayMilliseconds 0
```

Default: 600 ms for each simulated step.

Reservation duration:

```text
-MockLeaseSeconds 30
```

The app currently uses 5 seconds for faster local feedback. The contract uses 30 seconds.

## Contract

`Contracts/payments/openapi.yaml` is the source of truth for the payment API.

### Create payment

| Request | Response | App behavior |
| --- | --- | --- |
| `POST /payments` with `Idempotency-Key` | `201` with the payment. Repeating the same key with the same body returns the same result with `Idempotent-Replayed: true`. | Show receipt |
| | `402` final decline, stored and replayed for the same key | Show decline; the next attempt is a new payment intent |
| | `409` the same key is still processing | Keep the result as not confirmed |
| | `410` the key is past its retention period | Do not resend automatically |
| | `422` the key was already used with a different body | Treat as a rejected request |
| | `400` missing header or invalid body | Treat as a rejected request |
| | `5xx`, timeout, lost connection, or unreadable `2xx` | Treat as not confirmed |

### Check payment attempt

| Request | Response | App behavior |
| --- | --- | --- |
| `GET /payment-attempts/{key}` | `200` with `processing` | Wait and keep the same intent |
| | `200` with `succeeded` and payment data | Show receipt |
| | `200` with `declined` and error data | Show decline |
| | `404` no financial effect exists for this key | Send the same `POST` again with the same key |
| | `410` the key existed, but its stored result expired | Do not resend automatically |

The backend must guarantee:

- reserve the idempotency key before processing, with a uniqueness check;
- commit the financial effect and stored result atomically;
- expire reservations that have no result;
- allow only the active reservation owner to store the result;
- compare the complete request body when a key is reused;
- avoid storing validation errors (`400`);
- keep completed results for 24 hours;
- keep a tombstone after result expiration so the same key does not silently become a new payment during that period.

Error codes and names are defined by this contract and may evolve as `ledger-bff` and `ledger-core` are implemented.

## Connecting to a real backend

### Run contract tests

```sh
cd ContractTests
LEDGERCORE_BASE_URL=http://localhost:8080/v1 swift test
```

Each test runs with fresh idempotency keys.

Scenarios that depend on injected failures, limit-based declines, or the test clock remain in `PaymentsTestSupportTests` and only run against the mock.

### Run the app against a real backend

Set the `PAYMENTS_BASE_URL` build setting on the `Ledger` target.

Example:

```text
https://api.example.com/v1
```

The value reaches `Info.plist` as `PaymentsBaseURL`.

When `PaymentsBaseURL` has a value, `AppDependencies` creates `HTTPPaymentTransport` using `URLSession`, and the mock panel is hidden.

When it is empty, the app uses `MockPaymentHTTPServer`.

## Known limits

- `PaymentIntent` currently lives in the view controller. If the process dies after an unknown result, the idempotency key is lost. The app may need to persist the intent until the final result is known.
- Recovery currently starts when the user taps "Verificar pagamento". The app does not poll the payment status automatically.
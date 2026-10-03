# Ledger iOS

The iOS client of the Ledger Platform.

The first feature implemented here is payment reliability: making sure a payment is charged once, even when the
network fails or the response never arrives. The current code covers:

- `PaymentIntent`, which keeps the same idempotency key across retries of one payment;
- idempotent `POST /payments` with an `Idempotency-Key` header;
- unknown outcomes (timeouts, lost responses, `5xx`) treated as "not confirmed", never as "failed";
- status recovery through `GET /payment-attempts/{key}` instead of sending a second `POST`;
- a mock backend that follows the same HTTP contract;
- contract tests that run against the mock and, optionally, against a real backend;
- failure simulation (lost response, crash before commit, failure after commit).

The mock backend is development and test infrastructure. It lets the app and the tests run without a server. It
is not production backend code.

Requirements: Xcode 16 or later, iOS 17+, Swift 6 language mode. No external dependencies.

## Ledger Platform

| Repository | Role |
| --- | --- |
| `ledger-ios` | iOS client (this repository) |
| `ledger-bff` | Backend for Frontend for mobile clients |
| `ledger-core` | Core financial backend |
| `ledger-platform-roadmap` | Platform roadmap |

## Structure

| Where | What |
| --- | --- |
| `App/` | App lifecycle: `AppDelegate`, `SceneDelegate`, `AppDependencies` (composition) and `Info.plist`. |
| `Features/Payments/UI/` | `PaymentViewController`, `PaymentView`, `LabViewController` and `MockServerPanelView`. |
| `Packages/Payments/` | Client side: `PaymentIntent`, `PaymentClient`, `HTTPPaymentTransport`, `PaymentStatus`, `PaymentError` and the wire formats, plus `PaymentsTests` (same key on retry, mapping of HTTP responses). |
| `Packages/PaymentsTestSupport/` | In-memory server that follows the contract: `MockPaymentHTTPServer` (network, routes, simulated failures), `MockPaymentBackend` (keys, leases, retention) and the ledger, plus `PaymentsTestSupportTests` (one debit per key, stored decline, crash before commit, expired lease, a run that lost its lease, and a key expired after retention). |
| `ContractTests/` | `PaymentsContractTests`: the contract checked over HTTP, against the mock and, optionally, a real backend. Kept separate from both packages' own test suites. |
| `Contracts/payments/openapi.yaml` | HTTP contract between the app and the backend, including the idempotency rules. |
| `LedgerTests/` | Hosted tests: disabled button, recovery through the status check, resend with the same key when the server does not know the attempt, waiting while processing, stopping without resend when the key expired, new payment, and decline. |
| `LedgerUITests/` | UI tests: lost response and recovery, a second tap on the disabled button, and a new payment. |

The app depends on the local packages `Packages/Payments` and `Packages/PaymentsTestSupport` through the `Payments` and `PaymentsTestSupport` products. `PaymentsTestSupport` is development and test infrastructure only: the app links it today because there is no real backend yet, but it carries no production logic.

## Running

1. Open `Ledger.xcodeproj` and select the `Ledger` scheme.
2. Pick an iPhone simulator and run with ⌘R.
3. ⌘U runs the hosted tests and the UI tests.

From the terminal:

```sh
# each package
(cd Packages/Payments && swift test)
(cd Packages/PaymentsTestSupport && swift test)

# contract tests, against the mock
(cd ContractTests && swift test)

# app, hosted tests and UI tests
xcodebuild -project Ledger.xcodeproj -scheme Ledger \
  -destination 'platform=iOS Simulator,name=iPhone 13 Pro Max' \
  CODE_SIGNING_ALLOWED=NO test
```

Use a simulator that exists in your installation. If `xcode-select` points to the Command Line Tools, prefix the
commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

### Mock backend

By default the mock processes the first payment and loses the response. The app shows "Não foi possível confirmar
o pagamento". On the next tap ("Verificar pagamento") it checks the attempt for that key instead of sending another
`POST`, finds the payment and shows the receipt. The "Servidor simulado" panel shows 1 `POST`, 1 status check and
1 debit in the ledger.

The "Falha no próximo POST" picker in the panel chooses what happens to the next payment:

- **Perder resposta** (lose response): the server debits, but the response never arrives. The status check finds
  the payment.
- **Queda antes** (crash before commit): the server reserves the key and crashes before debiting. The status check
  returns "processing" until the lease expires (5 s in the app). After that, recovery resends with the same key.

Launch arguments (Product › Scheme › Edit Scheme › Arguments):

- `-MockFirstFault none | loseResponse | crashBeforeCommit | failAfterCommit` (default `loseResponse`).
- `-MockDelayMilliseconds 0`: network and processing latency (default 600 ms each).
- `-MockLeaseSeconds 30`: how long a lease without a result lasts (default 5 s in the app, 30 s in the contract).

## Contract

`Contracts/payments/openapi.yaml` is the source of truth. In short:

| Request | Response | In the app |
| --- | --- | --- |
| `POST /payments` with `Idempotency-Key` | `201` with the payment. Same key and same body return the same status and body, with `Idempotent-Replayed: true`. | Receipt |
| | `402` final decline, stored and replayed for the same key | Decline; the next try is a new intent |
| | `409` the same key is still processing | Not confirmed |
| | `410` the key is past its retention period (not processed again) | Not confirmed |
| | `422` the key was already used with a different body | Decline |
| | `400` missing header or invalid body (key is not reserved) | Decline |
| | `5xx`, timeout, lost connection, unreadable `2xx` | Not confirmed |
| `GET /payment-attempts/{key}` | `200` with `processing`, `succeeded` (with the payment) or `declined` (with the error) | Wait, receipt or decline |
| | `404` nothing was debited with this key (never arrived, or lease abandoned) | Resend the `POST` with the same key |
| | `410` the key existed, but the result was dropped after retention | No resend. Tells the user it cannot confirm and offers a new payment |

Rules the backend must guarantee, all covered by the mock and the tests:

- reserve the key with a uniqueness check before processing;
- debit and store the result in the same transaction;
- expire leases without a result (30 s) and only let the lease owner store the result;
- compare the whole body when a key is reused;
- do not store validation errors (`400`);
- keep the result of completed keys for 24 h. After that, keep remembering that the key existed and return `410` on
  both the status check and the `POST`, so the same key never becomes a new payment.

Error codes and names are defined by this contract and may change as `ledger-bff` and `ledger-core` evolve.

## Connecting to a real backend

1. Run the contract tests against it:

   ```sh
   cd ContractTests
   LEDGERCORE_BASE_URL=http://localhost:8080/v1 swift test
   ```

   Each test runs against the mock and against the given URL, with fresh keys on every run. Scenarios that depend
   on injected failures, limit declines or the clock live in `PaymentsTestSupportTests` and only run on the mock.

2. Set the `PAYMENTS_BASE_URL` build setting on the `Ledger` target, for example `https://api.example.com/v1`.
   It reaches `Info.plist` as `PaymentsBaseURL`. When it has a value, `AppDependencies` builds
   `HTTPPaymentTransport` on top of `URLSession` and the mock panel is hidden. When it is empty, the app uses
   `MockPaymentHTTPServer`.

## Known limits

- The `PaymentIntent` lives in the view controller. If the process dies after a timeout, the key is lost. The app
  may need to persist it until the result is known.
- Recovery happens when the user taps "Verificar pagamento". The app does not check the status on its own.

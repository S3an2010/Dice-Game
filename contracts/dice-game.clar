;; dice-game.clar - Optimized and Fixed Version
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u400))
(define-constant err-invalid-bet (err u401))
(define-constant err-insufficient-funds (err u402))
(define-constant err-game-not-found (err u403))
(define-constant err-invalid-prediction (err u404))
(define-constant err-game-already-resolved (err u405))
(define-constant err-invalid-dice-roll (err u406))

;; Game status constants
(define-constant status-pending "pending")
(define-constant status-won "won")
(define-constant status-lost "lost")

;; Bet type constants
(define-constant bet-type-number "number")
(define-constant bet-type-high "high")
(define-constant bet-type-low "low")

;; Game configuration constants
(define-constant min-bet-amount u1000000) ;; 1 STX minimum bet
(define-constant max-house-edge u20) ;; Maximum 20% house edge
(define-constant number-bet-multiplier u6)
(define-constant high-low-bet-multiplier u2)

(define-map games
  { game-id: uint }
  {
    player: principal,
    bet-amount: uint,
    prediction: uint,
    bet-type: (string-ascii 20),
    dice-result: (optional uint),
    payout: uint,
    status: (string-ascii 20),
    block-created: uint
  }
)

(define-data-var next-game-id uint u1)
(define-data-var house-edge uint u5) ;; 5% house edge
(define-data-var contract-balance uint u0)

;; Enhanced validation for bet amounts and predictions
(define-private (is-valid-bet-amount (amount uint))
  (>= amount min-bet-amount)
)

(define-private (is-valid-dice-number (number uint))
  (and (>= number u1) (<= number u6))
)

(define-private (is-valid-high-low-prediction (prediction (string-ascii 20)))
  (or (is-eq prediction bet-type-high) (is-eq prediction bet-type-low))
)

(define-private (is-valid-game-id (game-id uint))
  (and (> game-id u0) (< game-id (var-get next-game-id)))
)

;; Roll dice for specific number prediction (1-6)
(define-public (roll-dice-number (prediction uint) (bet-amount uint))
  (let ((game-id (var-get next-game-id)))
    ;; Validations
    (asserts! (is-valid-dice-number prediction) err-invalid-prediction)
    (asserts! (is-valid-bet-amount bet-amount) err-invalid-bet)

    ;; Transfer bet amount to contract
    (try! (stx-transfer? bet-amount tx-sender (as-contract tx-sender)))

    ;; Update contract balance
    (var-set contract-balance (+ (var-get contract-balance) bet-amount))

    ;; Create game record
    (map-set games { game-id: game-id }
      {
        player: tx-sender,
        bet-amount: bet-amount,
        prediction: prediction,
        bet-type: bet-type-number,
        dice-result: none,
        payout: u0,
        status: status-pending,
        block-created: block-height
      }
    )

    ;; Increment game ID
    (var-set next-game-id (+ game-id u1))
    (ok game-id)
  )
)

;; Roll dice for high (4-6) or low (1-3) prediction
(define-public (roll-dice-high-low (prediction (string-ascii 20)) (bet-amount uint))
  (let ((game-id (var-get next-game-id)))
    ;; Validations
    (asserts! (is-valid-high-low-prediction prediction) err-invalid-prediction)
    (asserts! (is-valid-bet-amount bet-amount) err-invalid-bet)

    ;; Transfer bet amount to contract
    (try! (stx-transfer? bet-amount tx-sender (as-contract tx-sender)))

    ;; Update contract balance
    (var-set contract-balance (+ (var-get contract-balance) bet-amount))

    ;; Create game record with encoded prediction
    (map-set games { game-id: game-id }
      {
        player: tx-sender,
        bet-amount: bet-amount,
        prediction: (if (is-eq prediction bet-type-high) u4 u3), ;; high = 4+, low = 3-
        bet-type: prediction,
        dice-result: none,
        payout: u0,
        status: status-pending,
        block-created: block-height
      }
    )

    ;; Increment game ID
    (var-set next-game-id (+ game-id u1))
    (ok game-id)
  )
)

;; Resolve a game with the dice roll result (only contract owner can call)
(define-public (resolve-game (input-game-id uint) (input-dice-roll uint))
  (let (
    ;; Validate inputs and create safe bindings
    (safe-game-id (begin
      (asserts! (is-eq tx-sender contract-owner) err-owner-only)
      (asserts! (is-valid-game-id input-game-id) err-game-not-found)
      input-game-id))
    (safe-dice-roll (begin
      (asserts! (is-valid-dice-number input-dice-roll) err-invalid-dice-roll)
      input-dice-roll))
    (game (unwrap! (map-get? games { game-id: safe-game-id }) err-game-not-found))
  )
    ;; Additional game state validation
    (asserts! (is-eq (get status game) status-pending) err-game-already-resolved)

    (let (
      (is-winner (calculate-winner game safe-dice-roll))
      (payout-amount (if is-winner (calculate-payout game) u0))
    )
      ;; Pay winner if applicable
      (if (and is-winner (> payout-amount u0))
        (begin
          (try! (as-contract (stx-transfer? payout-amount tx-sender (get player game))))
          (var-set contract-balance (- (var-get contract-balance) payout-amount))
        )
        ;; Update contract balance (house keeps the bet if player loses)
        true
      )

      ;; Update game record with results
      (map-set games { game-id: safe-game-id }
        (merge game {
          dice-result: (some safe-dice-roll),
          payout: payout-amount,
          status: (if is-winner status-won status-lost)
        })
      )

      (ok is-winner)
    )
  )
)

;; Calculate if the player won based on their prediction and dice result
(define-private (calculate-winner (game {player: principal, bet-amount: uint, prediction: uint, bet-type: (string-ascii 20), dice-result: (optional uint), payout: uint, status: (string-ascii 20), block-created: uint}) (dice-roll uint))
  (if (is-eq (get bet-type game) bet-type-number)
    ;; Number bet: exact match required
    (is-eq (get prediction game) dice-roll)
    ;; High/Low bet
    (if (is-eq (get bet-type game) bet-type-high)
      (>= dice-roll u4) ;; High: 4, 5, 6
      (<= dice-roll u3) ;; Low: 1, 2, 3
    )
  )
)

;; Calculate payout amount after house edge
(define-private (calculate-payout (game {player: principal, bet-amount: uint, prediction: uint, bet-type: (string-ascii 20), dice-result: (optional uint), payout: uint, status: (string-ascii 20), block-created: uint}))
  (let (
    (base-amount (get bet-amount game))
    (multiplier (if (is-eq (get bet-type game) bet-type-number) 
                   number-bet-multiplier 
                   high-low-bet-multiplier))
    (gross-payout (* base-amount multiplier))
    (house-fee (/ (* gross-payout (var-get house-edge)) u100))
  )
    (- gross-payout house-fee)
  )
)

;; Read-only functions
(define-read-only (get-game (game-id uint))
  (map-get? games { game-id: game-id })
)

(define-read-only (get-house-edge)
  (var-get house-edge)
)

(define-read-only (get-next-game-id)
  (var-get next-game-id)
)

(define-read-only (get-contract-balance)
  (var-get contract-balance)
)

(define-read-only (get-game-count)
  (- (var-get next-game-id) u1)
)

;; Administrative functions
(define-public (set-house-edge (new-edge uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-edge max-house-edge) err-invalid-bet)
    (var-set house-edge new-edge)
    (ok true)
  )
)

;; Emergency function to withdraw contract funds (owner only)
(define-public (withdraw-funds (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= amount (var-get contract-balance)) err-insufficient-funds)
    (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
    (var-set contract-balance (- (var-get contract-balance) amount))
    (ok amount)
  )
)
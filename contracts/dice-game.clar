;; dice-game.clar
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u400))
(define-constant err-invalid-bet (err u401))
(define-constant err-insufficient-funds (err u402))
(define-constant err-game-not-found (err u403))
(define-constant err-invalid-prediction (err u404))

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

(define-public (roll-dice-number (prediction uint) (bet-amount uint))
  (let ((game-id (var-get next-game-id)))
    (asserts! (and (>= prediction u1) (<= prediction u6)) err-invalid-prediction)
    (asserts! (> bet-amount u0) err-invalid-bet)

    (try! (stx-transfer? bet-amount tx-sender (as-contract tx-sender)))

    (map-set games { game-id: game-id }
      {
        player: tx-sender,
        bet-amount: bet-amount,
        prediction: prediction,
        bet-type: "number",
        dice-result: none,
        payout: u0,
        status: "pending",
        block-created: stacks-block-height
      }
    )

    (var-set next-game-id (+ game-id u1))
    (ok game-id)
  )
)

(define-public (roll-dice-high-low (prediction (string-ascii 20)) (bet-amount uint))
  (let ((game-id (var-get next-game-id)))
    (asserts! (or (is-eq prediction "high") (is-eq prediction "low")) err-invalid-prediction)
    (asserts! (> bet-amount u0) err-invalid-bet)

    (try! (stx-transfer? bet-amount tx-sender (as-contract tx-sender)))

    (map-set games { game-id: game-id }
      {
        player: tx-sender,
        bet-amount: bet-amount,
        prediction: (if (is-eq prediction "high") u4 u3), ;; high = 4-6, low = 1-3
        bet-type: prediction,
        dice-result: none,
        payout: u0,
        status: "pending",
        block-created: stacks-block-height
      }
    )

    (var-set next-game-id (+ game-id u1))
    (ok game-id)
  )
)

(define-public (resolve-game (game-id uint) (dice-roll uint))
  (let (
    (game (unwrap! (map-get? games { game-id: game-id }) err-game-not-found))
    (is-winner (calculate-winner game dice-roll))
    (payout-amount (if is-winner (calculate-payout game) u0))
  )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (and (>= dice-roll u1) (<= dice-roll u6)) err-invalid-prediction)
    (asserts! (is-eq (get status game) "pending") err-game-not-found)

    (if (and is-winner (> payout-amount u0))
      (try! (as-contract (stx-transfer? payout-amount tx-sender (get player game))))
      true
    )

    (map-set games { game-id: game-id }
      (merge game {
        dice-result: (some dice-roll),
        payout: payout-amount,
        status: (if is-winner "won" "lost")
      })
    )

    (ok is-winner)
  )
)

(define-private (calculate-winner (game {player: principal, bet-amount: uint, prediction: uint, bet-type: (string-ascii 20), dice-result: (optional uint), payout: uint, status: (string-ascii 20), block-created: uint}) (dice-roll uint))
  (if (is-eq (get bet-type game) "number")
    (is-eq (get prediction game) dice-roll)
    (if (is-eq (get bet-type game) "high")
      (>= dice-roll u4)
      (<= dice-roll u3)
    )
  )
)

(define-private (calculate-payout (game {player: principal, bet-amount: uint, prediction: uint, bet-type: (string-ascii 20), dice-result: (optional uint), payout: uint, status: (string-ascii 20), block-created: uint}))
  (let (
    (base-amount (get bet-amount game))
    (multiplier (if (is-eq (get bet-type game) "number") u6 u2))
    (gross-payout (* base-amount multiplier))
    (house-fee (/ (* gross-payout (var-get house-edge)) u100))
  )
    (- gross-payout house-fee)
  )
)

(define-read-only (get-game (game-id uint))
  (map-get? games { game-id: game-id })
)

(define-read-only (get-house-edge)
  (var-get house-edge)
)

(define-public (set-house-edge (new-edge uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-edge u20) err-invalid-bet) ;; Max 20% house edge
    (var-set house-edge new-edge)
    (ok true)
  )
)
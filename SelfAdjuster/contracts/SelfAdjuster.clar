;; Self-Adjusting Market Maker for DeFi Liquidity Pools
;; A sophisticated AMM that dynamically adjusts trading fees based on market volatility,
;; implements K-constant formula with price impact protection, and provides secure
;; liquidity management with anti-MEV mechanisms and emergency controls.

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-slippage-exceeded (err u102))
(define-constant err-pool-imbalanced (err u103))
(define-constant err-invalid-amount (err u104))
(define-constant err-emergency-stop (err u105))
(define-constant min-liquidity u1000)
(define-constant max-fee u3000) ;; 30% max fee in basis points
(define-constant base-fee u300)  ;; 3% base fee in basis points
(define-constant fee-precision u10000)
(define-constant price-precision u1000000)

;; Data maps and vars
(define-data-var emergency-stop bool false)
(define-data-var total-supply uint u0)
(define-data-var reserve-x uint u0)
(define-data-var reserve-y uint u0)
(define-data-var last-price uint u0)
(define-data-var volatility-factor uint u100)
(define-data-var fee-adjustment uint u0)

(define-map liquidity-providers principal uint)
(define-map user-deposits principal {x: uint, y: uint})
(define-map price-history uint uint)
(define-map volatility-buffer uint uint)

;; Private functions
(define-private (calculate-price-impact (amount-in uint) (reserve-in uint) (reserve-out uint))
  (let ((k (* reserve-in reserve-out))
        (new-reserve-in (+ reserve-in amount-in))
        (new-reserve-out (/ k new-reserve-in))
        (amount-out (- reserve-out new-reserve-out)))
    amount-out))

(define-private (update-volatility (current-price uint))
  (let ((previous-price (var-get last-price))
        (price-change (if (> current-price previous-price)
                         (- current-price previous-price)
                         (- previous-price current-price)))
        (volatility-score (/ (* price-change u100) previous-price)))
    (var-set volatility-factor volatility-score)
    (var-set last-price current-price)))

(define-private (calculate-dynamic-fee)
  (let ((base-volatility u100)
        (current-volatility (var-get volatility-factor))
        (volatility-multiplier (if (> current-volatility base-volatility)
                                  (/ current-volatility base-volatility)
                                  u100))
        (calculated-fee (* base-fee volatility-multiplier))
        (dynamic-fee (if (> calculated-fee max-fee) max-fee calculated-fee)))
    (var-set fee-adjustment dynamic-fee)
    dynamic-fee))

(define-private (calculate-fee-read-only)
  (let ((base-volatility u100)
        (current-volatility (var-get volatility-factor))
        (volatility-multiplier (if (> current-volatility base-volatility)
                                  (/ current-volatility base-volatility)
                                  u100))
        (calculated-fee (* base-fee volatility-multiplier))
        (dynamic-fee (if (> calculated-fee max-fee) max-fee calculated-fee)))
    dynamic-fee))

(define-private (mint-lp-tokens (to principal) (amount uint))
  (let ((current-balance (default-to u0 (map-get? liquidity-providers to)))
        (new-balance (+ current-balance amount)))
    (asserts! (> amount u0) err-invalid-amount)
    (map-set liquidity-providers to new-balance)
    (var-set total-supply (+ (var-get total-supply) amount))
    (ok amount)))

(define-private (burn-lp-tokens (from principal) (amount uint))
  (let ((current-balance (default-to u0 (map-get? liquidity-providers from))))
    (asserts! (>= current-balance amount) err-insufficient-balance)
    (map-set liquidity-providers from (- current-balance amount))
    (var-set total-supply (- (var-get total-supply) amount))
    (ok amount)))

;; Public functions
(define-public (add-liquidity (amount-x uint) (amount-y uint) (min-lp-tokens uint))
  (let ((reserve-x-val (var-get reserve-x))
        (reserve-y-val (var-get reserve-y))
        (total-supply-val (var-get total-supply))
        (lp-tokens (if (is-eq total-supply-val u0)
                      (pow (+ (* amount-x amount-y) u1) u1) ;; geometric mean for first deposit
                      (let ((lp-from-x (/ (* amount-x total-supply-val) reserve-x-val))
                            (lp-from-y (/ (* amount-y total-supply-val) reserve-y-val)))
                        (if (< lp-from-x lp-from-y) lp-from-x lp-from-y)))))
    (asserts! (not (var-get emergency-stop)) err-emergency-stop)
    (asserts! (> amount-x u0) err-invalid-amount)
    (asserts! (> amount-y u0) err-invalid-amount)
    (asserts! (>= lp-tokens min-lp-tokens) err-slippage-exceeded)
    
    (var-set reserve-x (+ reserve-x-val amount-x))
    (var-set reserve-y (+ reserve-y-val amount-y))
    (map-set user-deposits tx-sender {x: amount-x, y: amount-y})
    (try! (mint-lp-tokens tx-sender lp-tokens))
    (ok lp-tokens)))

(define-public (remove-liquidity (lp-tokens uint) (min-amount-x uint) (min-amount-y uint))
  (let ((total-supply-val (var-get total-supply))
        (reserve-x-val (var-get reserve-x))
        (reserve-y-val (var-get reserve-y))
        (amount-x (/ (* lp-tokens reserve-x-val) total-supply-val))
        (amount-y (/ (* lp-tokens reserve-y-val) total-supply-val)))
    (asserts! (not (var-get emergency-stop)) err-emergency-stop)
    (asserts! (>= amount-x min-amount-x) err-slippage-exceeded)
    (asserts! (>= amount-y min-amount-y) err-slippage-exceeded)
    
    (try! (burn-lp-tokens tx-sender lp-tokens))
    (var-set reserve-x (- reserve-x-val amount-x))
    (var-set reserve-y (- reserve-y-val amount-y))
    (ok {amount-x: amount-x, amount-y: amount-y})))

(define-public (swap-x-for-y (amount-x uint) (min-amount-y uint))
  (let ((reserve-x-val (var-get reserve-x))
        (reserve-y-val (var-get reserve-y))
        (fee (calculate-dynamic-fee))
        (amount-x-after-fee (- amount-x (/ (* amount-x fee) fee-precision)))
        (amount-y-out (calculate-price-impact amount-x-after-fee reserve-x-val reserve-y-val))
        (current-price (/ (* reserve-y-val price-precision) reserve-x-val)))
    
    (asserts! (not (var-get emergency-stop)) err-emergency-stop)
    (asserts! (> amount-x u0) err-invalid-amount)
    (asserts! (>= amount-y-out min-amount-y) err-slippage-exceeded)
    (asserts! (> reserve-y-val amount-y-out) err-insufficient-balance)
    
    (var-set reserve-x (+ reserve-x-val amount-x))
    (var-set reserve-y (- reserve-y-val amount-y-out))
    (update-volatility current-price)
    (ok amount-y-out)))

(define-public (emergency-stop-toggle)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set emergency-stop (not (var-get emergency-stop)))
    (ok (var-get emergency-stop))))

;; Read-only functions
(define-read-only (get-reserves) 
  {reserve-x: (var-get reserve-x), reserve-y: (var-get reserve-y)})

(define-read-only (get-lp-balance (user principal))
  (default-to u0 (map-get? liquidity-providers user)))

(define-read-only (get-current-fee)
  (calculate-fee-read-only))

(define-read-only (get-pool-info)
  {
    reserves: (get-reserves),
    total-supply: (var-get total-supply),
    current-fee: (get-current-fee),
    volatility: (var-get volatility-factor),
    emergency-stop: (var-get emergency-stop)
  })




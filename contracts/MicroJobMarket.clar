;; Contract Name: MicroJobMarket
;; Decentralized Micro-Job Marketplace (Clarity prototype)
;; Features:
;; - Posters create jobs and escrow STX to contract
;; - Workers accept jobs, submit work (as a hash/URI)
;; - Posters approve work -> funds released to worker
;; - Posters can cancel open/assigned jobs (refunds)
;; - Either party can raise a dispute; admin resolves disputes
;; - Read-only views for job data and owed amounts
;;
(define-data-var admin (optional principal) none)
(define-data-var job-counter uint u0)

;; Jobs map: id -> job tuple
(define-map jobs {id: uint}
  {poster: principal,
   worker: (optional principal),
   price: uint,
   status: (string-ascii 16),
   work-hash: (string-ascii 256)})

;; Status constants
(define-constant STATUS-OPEN (ok "OPEN"))
(define-constant STATUS-ASSIGNED (ok "ASSIGNED"))
(define-constant STATUS-SUBMITTED (ok "SUBMITTED"))
(define-constant STATUS-COMPLETED (ok "COMPLETED"))
(define-constant STATUS-CANCELLED (ok "CANCELLED"))
(define-constant STATUS-DISPUTED (ok "DISPUTED"))

;; Errors
(define-constant ERR-NOT-ADMIN (err u100))
(define-constant ERR-NOT-POSTER (err u101))
(define-constant ERR-NOT-WORKER (err u102))
(define-constant ERR-JOB-NOT-FOUND (err u103))
(define-constant ERR-INVALID-STATUS (err u104))
(define-constant ERR-INSUFFICIENT-FUNDS (err u105))
(define-constant ERR-TRANSFER-FAIL (err u106))
(define-constant ERR-ALREADY-ASSIGNED (err u107))
(define-constant ERR-NOTHING-TO-CLAIM (err u108))

;; Initialize admin (call once)
(define-public (initialize)
  (if (is-some (var-get admin))
      (err u200)
      (begin 
        (var-set admin (some tx-sender))
        (ok true))))

;; Helpers
(define-read-only (is-admin (who principal))
  (match (var-get admin) current-admin
    (is-eq who current-admin)
    false))

(define-read-only (get-job-count)
  (var-get job-counter))

(define-read-only (get-job (id uint))
  (let ((job (map-get? jobs {id: id})))
    (if (is-none job)
        (err u103)
        (ok (unwrap-panic job)))))

;; Create job: poster escrows `price` STX to contract and job is created
(define-public (create-job (price uint) (title (string-ascii 64)) (description (string-ascii 256)))
  (begin
    ;; require positive price
    (if (<= price u0)
        (err u105)
        (let ((id (var-get job-counter)))
          (if (is-ok (as-contract (stx-transfer? price tx-sender tx-sender)))
              (begin
                (map-set jobs {id: id} 
                         {poster: tx-sender, 
                          worker: none, 
                          price: price, 
                          status: "OPEN", 
                          work-hash: ""})
                (var-set job-counter (+ id u1))
                (ok id))
              (err u106))))))

;; Worker accepts a job
(define-public (accept-job (id uint))
  (match (map-get? jobs {id: id}) job
    (let ((status (get status job)))
      (if (is-eq status "OPEN")
          (let ((poster (get poster job)))
            (map-set jobs {id: id} {poster: poster, 
                                  worker: (some tx-sender), 
                                  price: (get price job), 
                                  status: "ASSIGNED", 
                                  work-hash: ""})
            (ok true))
          ERR-ALREADY-ASSIGNED))
    ERR-JOB-NOT-FOUND))

;; Worker submits work (provide a hash/URI)
(define-public (submit-work (id uint) (work-hash (string-ascii 256)))
  (let ((job (map-get? jobs {id: id})))
    (if (is-none job)
        ERR-JOB-NOT-FOUND
        (let ((some-job (unwrap-panic job)))
          (if (is-none (get worker some-job))
              (err u102)
              (let ((w (unwrap! (get worker some-job) (err u102))))
                (if (and (is-eq w tx-sender)
                         (is-eq (get status some-job) "ASSIGNED"))
                    (begin
                      (map-set jobs {id: id} 
                              {poster: (get poster some-job), 
                               worker: (some w), 
                               price: (get price some-job), 
                               status: "SUBMITTED", 
                               work-hash: work-hash})
                      (ok true))
                    (err u104))))))))

;; Poster approves submitted work -> release funds to worker
(define-public (approve-work (id uint))
  (match (map-get? jobs {id: id}) current-job
    (let ((poster (get poster current-job))
          (worker (get worker current-job))
          (status (get status current-job))
          (price (get price current-job)))
      (if (not (is-eq poster tx-sender))
          ERR-NOT-POSTER
          (if (not (is-eq status "SUBMITTED"))
              (err u104)
              (match worker active-worker
                (begin
                  (unwrap! (as-contract (stx-transfer? price tx-sender active-worker)) (err u106))
                  (map-set jobs {id: id} 
                          {poster: poster, 
                           worker: (some active-worker), 
                           price: price, 
                           status: "COMPLETED", 
                           work-hash: (get work-hash current-job)})
                  (ok true))
                (err u102)))))
    ERR-JOB-NOT-FOUND))

;; Poster cancels job (only if OPEN or ASSIGNED and no submission yet) -> refund poster
(define-public (cancel-job (id uint))
  (match (map-get? jobs {id: id})
    job
      (if (not (is-eq (get poster job) tx-sender))
          ERR-NOT-POSTER
          (let ((status (get status job)))
            (if (not (or (is-eq status "OPEN") (is-eq status "ASSIGNED")))
                (err u104)
                ;; ensure no submission yet
                (if (is-eq status "ASSIGNED")
                    (if (not (is-eq (get work-hash job) ""))
                        (err u104)
                        ;; proceed with refund and status update
                        (begin 
                          (unwrap! (as-contract (stx-transfer? (get price job) tx-sender (get poster job)))
                                  (err u106))
                          (map-set jobs {id: id}
                                  {poster: (get poster job),
                                   worker: (get worker job),
                                   price: (get price job),
                                   status: "CANCELLED",
                                   work-hash: (get work-hash job)})
                          (ok true)))
                    ;; for OPEN jobs, directly proceed with refund and status update
                    (begin 
                      (unwrap! (as-contract (stx-transfer? (get price job) tx-sender (get poster job)))
                              (err u106))
                      (map-set jobs {id: id}
                              {poster: (get poster job),
                               worker: (get worker job),
                               price: (get price job),
                               status: "CANCELLED",
                               work-hash: (get work-hash job)})
                      (ok true))))))
    ERR-JOB-NOT-FOUND))

;; Either party can raise a dispute
(define-public (raise-dispute (id uint) (reason (string-ascii 256)))
  (let ((job (map-get? jobs {id: id})))
    (if (is-none job)
        ERR-JOB-NOT-FOUND
        (let ((some-job (unwrap-panic job)))
          (if (or (is-eq (get status some-job) "ASSIGNED") 
                  (is-eq (get status some-job) "SUBMITTED"))
              (begin
                (map-set jobs {id: id} 
                        {poster: (get poster some-job), 
                         worker: (get worker some-job), 
                         price: (get price some-job), 
                         status: "DISPUTED", 
                         work-hash: (get work-hash some-job)})
                (ok true))
              (err u104))))))

;; Admin resolves dispute: pays either poster (refund) or worker (release) based on `ruling` boolean
(define-public (resolve-dispute (id uint) (pay-worker bool))
  (let ((job (map-get? jobs {id: id})))
    (if (not (is-admin tx-sender))
        ERR-NOT-ADMIN
        (if (is-none job)
            ERR-JOB-NOT-FOUND
            (let ((some-job (unwrap-panic job)))
              (if (is-eq (get status some-job) "DISPUTED")
                  (if pay-worker
                      (let ((worker (get worker some-job)))
                        (if (is-none worker)
                            (err u102)
                            (let ((some-w (unwrap-panic worker)))
                              (let ((tx (stx-transfer? (get price some-job) 
                                                     (as-contract tx-sender) 
                                                     some-w)))
                                (if (is-ok tx)
                                    (begin
                                      (map-set jobs {id: id} 
                                              {poster: (get poster some-job), 
                                               worker: (some some-w),
                                               price: (get price some-job),
                                               status: "COMPLETED",
                                               work-hash: (get work-hash some-job)})
                                      (ok true))
                                    (err u106))))))
                      ;; else refund poster
                      (let ((tx (stx-transfer? (get price some-job) 
                                             (as-contract tx-sender)
                                             (get poster some-job))))
                        (if (is-ok tx)
                            (begin
                              (map-set jobs {id: id} 
                                      {poster: (get poster some-job),
                                       worker: (get worker some-job),
                                       price: (get price some-job),
                                       status: "CANCELLED",
                                       work-hash: (get work-hash some-job)})
                              (ok true))
                            (err u106))))
                  (err u104)))))))

;; Read-only: view owed amount for a job (returns price if COMPELTED pending transfer? or 0)
(define-read-only (view-escrow (id uint))
  (let ((job (map-get? jobs {id: id})))
    (if (is-none job)
        (err u103)
        (ok (let ((j (unwrap-panic job)))
              (let ((status (get status j)))
                (if (or (is-eq status "OPEN") 
                       (is-eq status "ASSIGNED") 
                       (is-eq status "SUBMITTED") 
                       (is-eq status "DISPUTED"))
                    (get price j)
                    u0)))))))

;; Convenience read-only: list job brief
(define-read-only (job-summary (id uint))
  (let ((job (map-get? jobs {id: id})))
    (if (is-none job)
        ERR-JOB-NOT-FOUND
        (let ((j (unwrap-panic job)))
          (ok {id: id, 
              poster: (get poster j), 
              worker: (get worker j), 
              status: (get status j), 
              price: (get price j)})))))
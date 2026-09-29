/* ============================================================
   Olist 재구매 유도 전략 분석 — 전체 쿼리
   데이터: 캐글 Olist 브라질 이커머스 공개 데이터
   도구: SQLite (DB Browser for SQLite)
   ============================================================ */


/* ------------------------------------------------------------
   0. 기초 모수 확인
   ------------------------------------------------------------ */

-- 배송완료 주문 이력이 있는 고유 고객 수
SELECT COUNT(DISTINCT c.customer_unique_id)
FROM orders o JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered';
-- 결과: 93,358명

-- 관측 기간 (전체 주문 기준 / 배송완료 주문 기준)
SELECT MIN(order_purchase_timestamp), MAX(order_purchase_timestamp) FROM orders;
SELECT MIN(order_purchase_timestamp), MAX(order_purchase_timestamp)
FROM orders WHERE order_status = 'delivered';


/* ------------------------------------------------------------
   1. 재구매 정의 및 검증
   재구매 = 첫 주문 이후 24시간을 초과하는 시점에 발생한 주문이
   하나라도 있는 경우. (첫·두 번째 주문 간격만 보면 당일 분할
   주문 뒤의 실제 재구매를 놓치므로, 첫 주문 이후 전체 주문 중
   24시간을 초과하는 가장 이른 시점을 기준으로 판정한다.)
   ------------------------------------------------------------ */

WITH ranked AS (
    SELECT c.customer_unique_id AS uid,
           o.order_purchase_timestamp AS ts,
           ROW_NUMBER() OVER (
               PARTITION BY c.customer_unique_id
               ORDER BY o.order_purchase_timestamp) AS rn
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
),
first_o AS (
    SELECT uid, ts AS first_ts FROM ranked WHERE rn = 1
)
SELECT COUNT(DISTINCT f.uid) AS repeat_customers
FROM first_o f
JOIN ranked r ON r.uid = f.uid
WHERE julianday(r.ts) - julianday(f.first_ts) >= 1;
-- 결과: 1,993명 (2.13%)

-- 컷오프 민감도 확인 (1시간 / 6시간 / 24시간)
-- 위 쿼리의 ">= 1"을 ">= 1.0/24"(1시간), ">= 6.0/24"(6시간)로 바꿔 반복 실행
-- 결과: 1시간 2,046명(2.19%) / 6시간 2,022명(2.17%) / 24시간 1,993명(2.13%)
-- → 컷오프를 바꿔도 2.13~2.19% 범위로 안정적


/* ------------------------------------------------------------
   2. 재구매 시점 분포 (4-1)
   ------------------------------------------------------------ */

WITH ranked AS (
    SELECT customer_unique_id, order_purchase_timestamp,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp) AS rn
    FROM orders o JOIN customers c ON o.customer_id = c.customer_id
    WHERE order_status = 'delivered'
),
first_o AS (
    SELECT customer_unique_id, order_purchase_timestamp AS first_time
    FROM ranked WHERE rn = 1
),
first_repeat AS (   -- 첫 주문 이후 24시간 초과, 가장 이른 재주문 시점
    SELECT f.customer_unique_id, MIN(r.order_purchase_timestamp) AS repeat_time,
        f.first_time
    FROM first_o f JOIN ranked r ON f.customer_unique_id = r.customer_unique_id
    WHERE julianday(r.order_purchase_timestamp) - julianday(f.first_time) >= 1
    GROUP BY f.customer_unique_id
)
SELECT CASE
        WHEN julianday(repeat_time)-julianday(first_time) BETWEEN 1 AND 7 THEN '1~7일'
        WHEN julianday(repeat_time)-julianday(first_time) BETWEEN 8 AND 30 THEN '8~30일'
        WHEN julianday(repeat_time)-julianday(first_time) BETWEEN 31 AND 90 THEN '31~90일'
        WHEN julianday(repeat_time)-julianday(first_time) BETWEEN 91 AND 180 THEN '91~180일'
        ELSE '181일 이상' END AS bucket,
    COUNT(*)
FROM first_repeat GROUP BY bucket;
-- 결과: 1~7일 168명 / 8~30일 380명 / 31~90일 500명 / 91~180일 414명 / 181일+ 531명


/* ------------------------------------------------------------
   3. H1 — 첫 주문 배송 지연 여부별 재구매율
   ------------------------------------------------------------ */

WITH ranked AS (
    SELECT customer_unique_id, order_purchase_timestamp,
        order_delivered_customer_date, order_estimated_delivery_date,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp) AS rn
    FROM orders o JOIN customers c ON o.customer_id = c.customer_id
    WHERE order_status = 'delivered'
),
first_o AS (
    SELECT customer_unique_id, order_purchase_timestamp AS first_time,
        CASE WHEN order_delivered_customer_date > order_estimated_delivery_date
             THEN '지연' ELSE '정시' END AS delivery_status
    FROM ranked WHERE rn = 1
),
repeaters AS (
    SELECT DISTINCT f.customer_unique_id
    FROM first_o f JOIN ranked r ON f.customer_unique_id = r.customer_unique_id
    WHERE julianday(r.order_purchase_timestamp) - julianday(f.first_time) >= 1
)
SELECT f.delivery_status, COUNT(*) AS total_customers,
    SUM(CASE WHEN r.customer_unique_id IS NOT NULL THEN 1 ELSE 0 END) AS repeat_customers
FROM first_o AS f
LEFT JOIN repeaters AS r ON f.customer_unique_id = r.customer_unique_id
GROUP BY f.delivery_status;
-- 결과: 정시 85,754명 중 1,869명(2.18%) / 지연 7,604명 중 124명(1.63%)
-- 카이제곱 검정(Python scipy): χ²=9.81, p=.002


/* ------------------------------------------------------------
   4. H2 — 첫 주문 리뷰 점수별 재구매율
   ------------------------------------------------------------ */

WITH ranked AS (
    SELECT customer_unique_id, order_purchase_timestamp, order_id,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp) AS rn
    FROM orders o JOIN customers c ON o.customer_id = c.customer_id
    WHERE order_status = 'delivered'
),
review_dedup AS (   -- 한 주문에 리뷰가 여러 건인 경우 최신 것 1건만
    SELECT order_id, review_score,
        ROW_NUMBER() OVER (PARTITION BY order_id
            ORDER BY review_creation_date DESC) AS rn2
    FROM order_reviews
),
first_o AS (
    SELECT ranked.customer_unique_id, ranked.order_purchase_timestamp AS first_time,
        review_dedup.review_score
    FROM ranked
    LEFT JOIN review_dedup ON ranked.order_id = review_dedup.order_id
        AND review_dedup.rn2 = 1
    WHERE ranked.rn = 1
),
repeaters AS (
    SELECT DISTINCT f.customer_unique_id
    FROM first_o f JOIN ranked r ON f.customer_unique_id = r.customer_unique_id
    WHERE julianday(r.order_purchase_timestamp) - julianday(f.first_time) >= 1
)
SELECT COALESCE(CAST(f.review_score AS TEXT), '리뷰없음') AS grp,
    COUNT(*) AS total_customers,
    SUM(CASE WHEN r.customer_unique_id IS NOT NULL THEN 1 ELSE 0 END) AS repeat_customers
FROM first_o AS f
LEFT JOIN repeaters AS r ON f.customer_unique_id = r.customer_unique_id
GROUP BY grp;
-- 결과: 1점 1.71% / 2점 1.69% / 3점 1.93% / 4점 1.99% / 5점 2.31% / 리뷰없음 1.94%


/* ------------------------------------------------------------
   5. RF 세그먼트 정의
   F는 1회 vs 2회 이상으로 이진 분리, R(첫 구매 후 경과일)로
   F=1 그룹을 3단계 세분 (90일 컷 = 재구매 시점 분포의 중앙값)
   ------------------------------------------------------------ */

WITH ranked AS (
    SELECT customer_unique_id, order_purchase_timestamp,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp) AS rn
    FROM orders o JOIN customers c ON o.customer_id = c.customer_id
    WHERE order_status = 'delivered'
),
first_o AS (
    SELECT customer_unique_id, order_purchase_timestamp AS first_time FROM ranked WHERE rn=1
),
repeaters AS (
    SELECT DISTINCT f.customer_unique_id
    FROM first_o f JOIN ranked r ON f.customer_unique_id=r.customer_unique_id
    WHERE julianday(r.order_purchase_timestamp)-julianday(f.first_time) >= 1
),
segmented AS (
    SELECT f.customer_unique_id,
        CASE
            WHEN rp.customer_unique_id IS NOT NULL THEN '충성 재구매 고객'
            WHEN julianday((SELECT MAX(order_purchase_timestamp) FROM orders)) - julianday(f.first_time) <= 90 THEN '골든타임 잠재고객'
            WHEN julianday((SELECT MAX(order_purchase_timestamp) FROM orders)) - julianday(f.first_time) <= 180 THEN '재고려 대상'
            ELSE '이탈 고객'
        END AS segment
    FROM first_o f
    LEFT JOIN repeaters rp ON f.customer_unique_id = rp.customer_unique_id
)
SELECT segment, COUNT(*) FROM segmented GROUP BY segment;
-- 결과: 충성 재구매 1,993명(2.1%) / 골든타임 8,936명(9.6%) /
--       재고려 대상 17,499명(18.7%) / 이탈 고객 64,930명(69.6%)


/* ------------------------------------------------------------
   6. 세그먼트별 이탈 요인 교차 (시기 효과 보정)
   배송 지연율이 시기별로 크게 요동쳐(2017-11 14.4%, 2018-03 21.4%)
   세그먼트(첫 구매 시점 기준)와 시기가 혼입될 위험이 있어,
   각 고객의 지연 여부·리뷰점수에서 해당 월 평균을 뺀 상대값으로 재계산.
   ------------------------------------------------------------ */

WITH ranked AS (
    SELECT customer_unique_id, order_purchase_timestamp, order_id,
        order_delivered_customer_date, order_estimated_delivery_date,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp) AS rn
    FROM orders o JOIN customers c ON o.customer_id = c.customer_id
    WHERE order_status = 'delivered'
),
review_dedup AS (
    SELECT order_id, review_score,
        ROW_NUMBER() OVER (PARTITION BY order_id
            ORDER BY review_creation_date DESC) AS rn2
    FROM order_reviews
),
first_o AS (
    SELECT r.customer_unique_id, r.order_purchase_timestamp AS first_time,
        strftime('%Y-%m', r.order_purchase_timestamp) AS month,
        CASE WHEN r.order_delivered_customer_date > r.order_estimated_delivery_date THEN 1 ELSE 0 END AS is_delayed,
        rv.review_score
    FROM ranked r
    LEFT JOIN review_dedup rv ON r.order_id = rv.order_id AND rv.rn2 = 1
    WHERE r.rn = 1
),
repeaters AS (
    SELECT DISTINCT f.customer_unique_id
    FROM first_o f JOIN ranked r ON f.customer_unique_id=r.customer_unique_id
    WHERE julianday(r.order_purchase_timestamp)-julianday(f.first_time) >= 1
),
monthly_avg AS (
    SELECT month, AVG(is_delayed) m_delay, AVG(review_score) m_review FROM first_o GROUP BY month
),
adjusted AS (
    SELECT f.customer_unique_id, f.first_time,
        (f.is_delayed - m.m_delay) AS excess_delay,
        (f.review_score - m.m_review) AS excess_review
    FROM first_o f JOIN monthly_avg m ON f.month = m.month
),
segmented AS (
    SELECT a.*,
        CASE
            WHEN rp.customer_unique_id IS NOT NULL THEN '충성 재구매 고객'
            WHEN julianday((SELECT MAX(order_purchase_timestamp) FROM orders)) - julianday(a.first_time) <= 90 THEN '골든타임 잠재고객'
            WHEN julianday((SELECT MAX(order_purchase_timestamp) FROM orders)) - julianday(a.first_time) <= 180 THEN '재고려 대상'
            ELSE '이탈 고객'
        END AS segment
    FROM adjusted a LEFT JOIN repeaters rp ON a.customer_unique_id = rp.customer_unique_id
)
SELECT segment, COUNT(*), ROUND(AVG(excess_delay)*100,2) AS delay_diff_pct,
    ROUND(AVG(excess_review),3) AS review_diff
FROM segmented GROUP BY segment;
-- 결과: 충성 재구매 -1.10%p / +0.12점 (유일하게 유의미한 차이)
--       골든타임 +0.25%p / +0.005점, 재고려 -0.25%p / ±0.00점, 이탈 +0.07%p / -0.004점


/* ------------------------------------------------------------
   7. 참고 — 우측 절단 검증용 (배송완료 주문 최신일 확인)
   ------------------------------------------------------------ */

SELECT MAX(order_purchase_timestamp) FROM orders WHERE order_status='delivered';
-- 결과: 2018-08-29 (전체 주문 최신일 2018-10-17보다 약 7주 이른 날짜)

-- 세그먼트 대상 고객의 첫 구매 평균 결제액 (6장 쿠폰 단가 기준선)
WITH ranked AS (
    SELECT customer_unique_id, order_id, order_purchase_timestamp,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY order_purchase_timestamp) AS rn
    FROM orders o JOIN customers c ON o.customer_id = c.customer_id
    WHERE order_status = 'delivered'
),
first_o AS (SELECT customer_unique_id, order_id FROM ranked WHERE rn=1)
SELECT AVG(p.payment_value) FROM first_o f JOIN order_payments p ON f.order_id=p.order_id;
-- 결과: R$153.55

# Resource Ledger — 設計の本質

あらゆるリソースの変動事実を統一的に記録するための構造パターンを整理する。

## 根底にある目的

このシステムの存在理由は **よりよい意思決定** にある。そのために:

- リソースの変動事実を統一的に記録する
- 過去の意思決定時に何のデータが利用可能だったかを再現できる
- 目標設定自体の振り返りと検証ができる

## 技術スタック

| 層 | 技術 | 役割 |
|---|---|---|
| DB | **XTDB v1** | bi-temporal ドキュメント DB |
| フレームワーク | **Biff** | Clojure Web フレームワーク（XTDB 統合済み） |
| ストレージ | **PostgreSQL**（JDBC） | XTDB のトランザクションログ + ドキュメントストア |
| クエリ | **Datalog** | XTDB v1 のネイティブクエリ言語 |
| スキーマ検証 | **Malli**（Biff 統合） | アプリ層でのドキュメントバリデーション |

### ドキュメントモデル

XTDB v1 はスキーマレスの EDN ドキュメント DB。DDL は不要。すべてのドキュメントは `:xt/id` を持つ EDN マップ:

```clojure
{:xt/id #uuid "..."
 :entry/owner  #uuid "..."
 :entry/delta  3000M
 :entry/track  :track/actual}
```

### bi-temporal

XTDB v1 はすべてのドキュメントに2つの時間軸を自動付与する:

- **tx-time**: いつ DB に書き込まれたか（不変。改竄不可能。自動）
- **valid-time**: いつに帰属するか（`::xt/put` 時にアプリが指定。後から修正可能）

これにより:

- entry の監査証跡・訂正履歴は tx-time が自動保証する。アプリ層で append-only 制約や逆仕訳パターンを実装する必要がない
- dimension ドキュメント（resource, owner, activity 等）の変更履歴も自動追跡される
- 「あの時はあの集計軸で、あのデータを見て意思決定していた」を DB のクエリだけで完全に復元できる

---

# Part 1: 設計

## 1. 中核パターン: 変動台帳（Delta Ledger）

本モデルの最も本質的な構造は「**変動の記録から状態を導出する**」パターン。

```
event (なぜ変わったか)
  └── entry (何がいくら変わったか)
        ↓ 集計
      balance (今いくらか)           ← 導出クエリ（ストック）
      period-sum (期間にいくら動いたか) ← 導出クエリ（フロー）
```

1つの event が複数の entry を生成するのが一般的。会計的な用途では1取引あたり 3〜5 entry になることが多い。

### entry から導出されるもの

| 導出 | 集計方法 | 用途 |
|------|----------|------|
| **balance** | `(xt/db node as-of-date)` でスナップショット → SUM | ストック性のあるリソースの残高 |
| **期間集計** | `get-start-valid-time` で valid-time 範囲フィルタ → SUM | フロー性のあるリソースの消費量・収支 |
| **track 間比較** | track 別 SUM の差分 | 見積精度の検証、予実差異分析 |
| **時系列推移** | valid-time 軸での集計 | トレンド把握 |

残高（balance）が有意味なのは「貯蔵」があるリソース — 獲得と消費の間に時間的ギャップがあり、その間にストックが存在するもの（Fisher の stock/flow 区分）。すべてのリソースに残高管理が必要なわけではない。

### 時間モデル: bi-temporal

XTDB が管理する2つの時間軸:

```
tx-time    = いつ DB に書き込まれたか（不変。自動。改竄不可能）
valid-time = いつに帰属するか（::xt/put 時にアプリが指定。後から修正可能）
```

この分離により:

- **後追い記録**: 12:00 の食事を 19:00 に記録 → valid-time=12:00, tx-time=19:00（自動）
- **過去の計画の復元**: tx-time で「3/1 時点で DB に存在していたデータ」を復元
- **遡及修正の透明性**: 同一 `:xt/id` で再 put しても、修正前の状態は tx-time で完全に復元可能

```clojure
;; 12:00 の食事を 19:00 に記録
(xt/submit-tx node
  [[::xt/put
    {:xt/id (random-uuid)
     :entry/event    ev-id
     :entry/owner    me-id
     :entry/resource bread-id
     :entry/track    :track/actual
     :entry/delta    -1M}
    #inst "2025-05-15T12:00"]])  ;; ← valid-time
;; tx-time は 19:00 が自動記録される
```

entry のドキュメントに日付属性は持たない。帰属時点は valid-time が担う。Datalog 内では `get-start-valid-time` で参照できる:

```clojure
;; 5月の entry を valid-time で範囲フィルタ
(xt/q (xt/db node)
  '{:find [?e ?delta]
    :where [[?e :entry/delta ?delta]
            [(get-start-valid-time ?e) ?vt]
            [(>= ?vt #inst "2025-05-01")]
            [(< ?vt #inst "2025-06-01")]]})
```

### 訂正パターン

entry の訂正は `::xt/put`（同一 `:xt/id` で新バージョン）/ `::xt/delete` で行う。tx-time が修正前の状態を自動保存する。

| 訂正の意図 | 操作 | 効果 |
|-----------|------|------|
| 金額訂正 | 同一 `:xt/id` で `::xt/put`（delta を修正） | 残高が修正される。旧値は tx-time に残る |
| 帰属時点の変更 | `::xt/delete`（旧 valid-time）+ `::xt/put`（新 valid-time） | 帰属時点が移動する。旧状態は tx-time に残る |
| 当期調整 | 新しい entry を `::xt/put`（valid-time = 今日、差額のみ） | 過去の残高は不変。差額は当期に計上 |
| 取消 | `::xt/delete` | entry が無効化される。存在していた事実は tx-time に残る |

```clojure
;; 金額訂正: 3000 → 3500（同一 ID で新バージョン）
(xt/submit-tx node
  [[::xt/put
    {:xt/id entry-id
     :entry/event ev-id :entry/owner me-id
     :entry/resource food-id :entry/track :track/actual
     :entry/delta 3500M}
    #inst "2025-05-15"]])
;; → tx-time に旧値 (3000) が自動保存

;; 取消
(xt/submit-tx node [[::xt/delete entry-id]])
```

「修正前はどうだったか」の復元:

```clojure
;; 6/10 に修正したが、3/1 時点では何が見えていたか？
(xt/q (xt/db node
        {::xt/valid-time #inst "2025-05-15"
         ::xt/tx {::xt/tx-time #inst "2025-03-01"}})
  '{:find [?e ?delta]
    :where [[?e :entry/delta ?delta]
            [?e :entry/resource ?rid]]
    :in [?rid]}
  food-id)
```

### 構造要素

| 要素 | 理由 |
|------|------|
| event → entry の 1:N 構造 | 変動の因果関係（なぜこの entry が存在するか）を保証 |
| tx-time（XTDB 自動） | 監査証跡と時点復元の前提。アプリ層での append-only 制約が不要 |
| valid-time（`::xt/put` 時に指定） | 業務時間の帰属。ドキュメント属性としては持たない |
| event の idempotency-key | 重複投入防止。アプリ層で検証 |
| resource の unit → unit-master 参照 | 単位の正規化。自由文字列による揺れ（h/hour/hours）を防止 |
| resource の parent → 階層構造 | 分類はツリーの中間ノードで表現。classification 属性は不要 |
| delta (BigDecimal) | 金額・時間・数量を統一的に扱う |
| delta != 0 制約 | 無意味なレコードの排除（アプリ層で検証） |

---

## 2. 多次元交点: キューブ構造

各 entry は「複数の軸の交点」に位置する。

```
entry = f(owner, activity, valid-time, track, resource)
          ↑       ↑          ↑            ↑       ↑
        誰の    何のため   いつの      記録文脈   何のリソース
```

### 6つの軸

| # | 軸 | 問い | 管理 |
|---|---|---|---|
| 1 | **owner** | 誰が責任を持つか | ドキュメント属性 |
| 2 | **activity** | 何のためか（nullable） | ドキュメント属性 |
| 3 | **valid-time** | いつに帰属するか | XTDB valid-time（`::xt/put` 時に指定） |
| 4 | **track** | どの記録文脈か（resource 別に定義） | ドキュメント属性 |
| 5 | **resource** | 何のリソースか | ドキュメント属性 |
| 6 | **event** | なぜ変わったか | ドキュメント属性 |

### 軸の分類

| 分類 | 軸 | 特徴 |
|------|---|------|
| **構造軸**（参照あり） | owner, activity, resource, event, track | 他ドキュメントへの参照 |
| **時間軸**（XTDB 管理） | valid-time | `::xt/put` 時にアプリが指定。Datalog 内で `get-start-valid-time` で参照 |

ドメイン固有の補足情報（対象メンバー、取引先等）は attrs に自由に格納する。コアスキーマに polymorphic 参照は持たない。

### entry のドキュメント構造

```clojure
{:xt/id          (random-uuid)          ;; XTDB PK
 :entry/event    event-id               ;; なぜ（→ event）
 :entry/owner    owner-id               ;; 誰が（→ owner）
 :entry/activity activity-id            ;; 何のために（→ activity, nullable）
 :entry/resource resource-id            ;; 何の（→ resource）
 :entry/track    :track/actual          ;; どの文脈で（→ track-master）
 :entry/delta    3000M                  ;; いくら（BigDecimal, != 0）
 :entry/attrs    {:member tanaka-id}}   ;; 補足（nullable, ドメイン固有）
;; 時間は XTDB が管理（ドキュメント外）:
;;   valid-time:  ::xt/put 時に指定
;;   tx-time:     自動（不変）
```

### 符号規約

- **正**: リソースの増加（収入、資産増、取得）
- **負**: リソースの減少（支出、資産減、消費）
- 会計アプリでは resource ツリーの分類（中間ノード）に応じて表示上の正負を解釈する。DB 上の符号規約は統一

---

## 3. トラック: resource 別の記録文脈

### track とは

track は entry の「記録文脈」を表す軸。「リソースが実際に動いた」事実と「予算としてこの値を設定した」事実を、同一リソース上で区別する。

**すべての entry は事実である。** track が区別するのは事実の種類:

| track の例 | 記録される事実 |
|------------|---------------|
| :track/actual | リソースが動いた事実（食費 3,000円を支出した） |
| :track/monthly-budget | 月次予算を設定した事実（食費の月予算を 30,000円にした） |
| :track/quarterly-target | 四半期目標を設定した事実（売上目標を 500万にした） |
| :track/weekly-capacity | 週次キャパシティを定義した事実（稼働可能時間を 40h にした） |

「計画は事実ではない」のではなく、**「計画を立てたこと」は事実**。過去の見積精度を検証するには、計画データが事実として不変に残っていることが前提になる。

### なぜ resource 別か

track の種類は resource ごとに異なる。全 resource に共通の track セットを強制できない:

| resource | 有効な track | 理由 |
|----------|-------------|------|
| 食費 | actual, monthly-budget | 月次予算管理 |
| 工数 | actual, weekly-capacity | 週次キャパシティ管理 |
| 食パン | actual | 在庫のみ。予算は不要 |
| 売上 | actual, quarterly-target, revised-target | 四半期目標 + 見直し |

### track-master と resource の tracks

```clojure
;; track-master ドキュメント: track の種類を定義（キーワード ID）
{:xt/id :track/actual           :track/name "actual"           :track/granularity :point}
{:xt/id :track/monthly-budget   :track/name "monthly-budget"   :track/granularity :month}
{:xt/id :track/weekly-capacity  :track/name "weekly-capacity"  :track/granularity :week}
{:xt/id :track/quarterly-target :track/name "quarterly-target" :track/granularity :quarter}

;; resource ドキュメントに許可 track をセットで保持
{:xt/id #uuid "..."
 :resource/name "食費"
 :resource/category :monetary
 :resource/tracks #{:track/actual :track/monthly-budget}}
;; → entry の track はこのセットに含まれる値のみ許可（アプリ層で検証）
```

### resource ツリーの純粋性

track を resource 別に制御することで、**resource ツリーはドメインの存在論のみを反映する**:

```
✗ 汚染されたツリー          ✓ 純粋なツリー
monetary                     monetary
├── 食費                     ├── 食費         ← track で actual / budget を区別
├── 食費_予算                ├── 家賃
├── 食費_見込                └── 光熱費
├── 家賃
├── 家賃_予算
└── ...
```

### entry の時間モデル

track によって valid-time の時間的な意味が異なる。track-master の granularity がこれを定義する:

| granularity | valid-time の解釈 | 例 |
|-------------|-------------------|-----|
| :point | 時刻（いつ発生したか） | 12:00 に昼食 |
| :day | 日（その日に帰属） | 5/15 の食費 |
| :week | 週の初日（その週に帰属） | 第20週のキャパシティ |
| :month | 月の初日（その月に帰属） | 5月の予算 |
| :quarter | 四半期の初日 | Q2 の売上目標 |

期間の終了は valid-time + granularity から導出できるため、entry に期間終了を追加する必要はない。

### 設計原則

| 原則 | 説明 |
|------|------|
| actual は必須 | すべての resource に :track/actual が存在する。resource 作成時に自動付与 |
| track は不可侵 | 異なる track の entry は相互に干渉しない。actual の SUM と budget の SUM は独立 |
| 比較はクエリで | track 間の比較方法はアプリ層・BI層が選ぶ |
| 粒度は自由 | 同一 resource でも track ごとに粒度が異なりうる（月次予算 vs 日次実績） |

---

## 4. 階層ディメンション: ツリー構造

主要ディメンション（owner, activity, resource）はすべて階層を持つ。

```
親ノード (is-leaf=false, 集計用・分類用)
├── 子ノード (is-leaf=false, サブ分類)
│   ├── 末端ノード (is-leaf=true, entry 記入可) ★
│   └── 末端ノード (is-leaf=true) ★
└── 末端ノード (is-leaf=true) ★
```

| 要素 | 理由 |
|------|------|
| parent による自己参照 | ドリルダウン・集計の軸 |
| is-leaf フラグ | 新規 entry の書き込み制御（二重計上防止） |
| 中間ノード = 分類 | ツリー構造自体が分類を表現する。classification 等の属性は不要 |

- `is-leaf` は **書き込み制御**であり、データ制約ではない。`::xt/put` 時に `is-leaf = true` を検証する（アプリ層）
- リーフが非リーフに変わっても、過去の entry は有効。合算は親ノードに自然に吸収される
- 「expense 配下の全 entry」等の分類クエリは ancestor ルールで再帰走査する:

```clojure
;; ancestor ルール（汎用。resource / owner / activity 共通で使える）
(xt/q db
  '{:find [?e ?delta]
    :where [(ancestor ?r ?expense-node)
            [?e :entry/resource ?r]
            [?e :entry/delta ?delta]]
    :rules [[(ancestor ?child ?anc)
             [?child :resource/parent ?anc]]
            [(ancestor ?child ?anc)
             [?child :resource/parent ?mid]
             (ancestor ?mid ?anc)]]
    :in [?expense-node]}
  expense-node-id)
```

### 階層の変更: リーフの分割

リーフノードを子に分割する場合（例: `bank-acc` → `bk1`, `bk2`）:

1. 元のリーフの `is-leaf` を false に変更（`::xt/put` で新バージョン。valid-time で変更時点を記録）
2. 新しい子リーフを `::xt/put`
3. 振替 event で元のリーフの残高を子リーフに移動

```clojure
(let [split-date #inst "2025-06-01"]
  (xt/submit-tx node
    [;; 1. 元のリーフを非リーフに変更
     [::xt/put (assoc bank-acc :resource/is-leaf false) split-date]
     ;; 2. 新しい子リーフを追加
     [::xt/put {:xt/id bk1-id :resource/name "bk1"
                :resource/parent bank-acc-id :resource/is-leaf true ...} split-date]
     [::xt/put {:xt/id bk2-id :resource/name "bk2"
                :resource/parent bank-acc-id :resource/is-leaf true ...} split-date]
     ;; 3. 振替 event + entries
     [::xt/put {:xt/id ev-id :event/description "銀行口座の分割"}]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/resource bank-acc-id :entry/delta -500000M
                :entry/track :track/actual ...} split-date]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/resource bk1-id :entry/delta 300000M
                :entry/track :track/actual ...} split-date]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/resource bk2-id :entry/delta 200000M
                :entry/track :track/actual ...} split-date]]))
```

分割前の is-leaf=true の状態は tx-time で復元可能。

### dimension の変更履歴

owner, activity, resource の変更（名称変更、階層の組み替え等）は `::xt/put` による新バージョン作成で行う。XTDB の bi-temporal により自動追跡される。

過去の任意の時点で「どの集計軸でデータを見ていたか」を再現できるため、意思決定時の文脈を完全に復元できる。

---

## 5. 統合の鍵: resource

「金額の科目」と「業務量の単位」を単一のツリーに統一する。

```
entry → :entry/resource  → resource ドキュメント（階層、カテゴリ分類）
      → :entry/track     → track-master ドキュメント
      → :entry/target    → polymorphic（entry の target-type で判別）
resource → :resource/unit → unit-master ドキュメント（単位の正規化）
```

### 統合で得られるもの

- **単一のドキュメントタイプで全リソースを記録** — クエリが統一的
- **新リソース種別の追加がドキュメント追加のみ** — スキーマ変更不要
- **balance が統一的** — resource で WHERE すれば種別ごとの残高
- **track が resource 別** — 予算・目標・キャパシティ等を resource の性質に応じて定義

### 統合で注意すべきこと

- **型安全性**: balance は resource 単位で集計するため、単位混在は発生しない。階層ロールアップはクエリ/BI層の責務
- **会計的な制約（貸借検証等）**: コアスキーマには含めない。拡張クエリで対応

---

## 6. コアスキーマと拡張の境界

### コアスキーマの責務: 集計のための最小構造

コアスキーマのドキュメントタイプは「entry の記録・集計に必要な最小構造」だけを持つ。業務的な意味は拡張ドキュメントが付与する。

すべてのドキュメントに valid-time / tx-time が XTDB により自動付与される。

| ドキュメントタイプ | 属性 | 役割 |
|---------|---------|------|
| **event** | :xt/id, idempotency-key, description | entry の存在理由 |
| **entry** | :xt/id, event, owner, activity, resource, track, delta, attrs | リソース変動の事実 |
| **owner** | :xt/id, parent, is-leaf, cd, name | 責任主体（階層） |
| **activity** | :xt/id, parent, is-leaf, cd, name | 活動（階層） |
| **resource** | :xt/id, parent, is-leaf, cd, name, category, unit, tracks | リソース種別（階層。分類はツリー構造で表現） |
| **unit-master** | :xt/id, name | 単位の正規化 |
| **track-master** | :xt/id (keyword), name, granularity | 記録文脈の種類 |

### Biff Malli スキーマ（例）

```clojure
(def schema
  {:entry/id :uuid
   :entry (doc {:required [[:xt/id          :entry/id]
                           [:entry/event    :uuid]
                           [:entry/owner    :uuid]
                           [:entry/resource :uuid]
                           [:entry/track    :keyword]
                           [:entry/delta    number?]]     ;; BigDecimal, != 0
                :optional [[:entry/activity :uuid]        ;; nullable
                           [:entry/attrs    :map]]})

   :event/id :uuid
   :event (doc {:required [[:xt/id              :event/id]
                           [:event/description  :string]]
                :optional [[:event/idempotency-key :string]]})

   :resource/id :uuid
   :resource (doc {:required [[:xt/id             :resource/id]
                              [:resource/cd       :string]
                              [:resource/name     :string]
                              [:resource/category :keyword]
                              [:resource/unit     :uuid]
                              [:resource/is-leaf  :boolean]]
                   :optional [[:resource/parent :uuid]
                              [:resource/tracks [:set :keyword]]]})

   :owner/id :uuid
   :owner (doc {:required [[:xt/id        :owner/id]
                           [:owner/cd     :string]
                           [:owner/name   :string]
                           [:owner/is-leaf :boolean]]
                :optional [[:owner/parent :uuid]]})

   :activity/id :uuid
   :activity (doc {:required [[:xt/id           :activity/id]
                              [:activity/cd     :string]
                              [:activity/name   :string]
                              [:activity/is-leaf :boolean]]
                   :optional [[:activity/parent :uuid]]})

   :unit/id :uuid
   :unit (doc {:required [[:xt/id     :unit/id]
                          [:unit/name :string]]})

   :track/id :keyword
   :track (doc {:required [[:xt/id              :track/id]
                           [:track/name         :string]
                           [:track/granularity  :keyword]]})})
```

### 拡張ドキュメントで対応する領域

同じ DB 内にコアスキーマとは別のドキュメントとして定義する。

| 関心事 | 例 | 拡張パターン |
|--------|---|------|
| ディメンションの業務属性 | activity の状態・期間・分類 | ドキュメントへの属性追加、または別ドキュメント |
| target の実体 | メンバー、取引先、材料 | target が参照するドキュメント |
| 契約管理 | 受注、発注、請求 | 別ドキュメントタイプ。activity への参照で紐付け |
| リソース間の導出関係 | 食品→栄養素の変換 | food-nutrition-profile 等のマッピングドキュメント |
| 貸借検証 | 借方合計 = 貸方合計 | クエリで検証 |

---

# Part 2: ユースケース

## UC1. 食品・栄養管理

食品の購入と消費を entry で記録し、栄養素は拡張ドキュメント経由で導出する。

### 軸のマッピング

| 軸 | 割り当て |
|---|---|
| owner | 自分（個人） |
| activity | lunch, dinner 等の食事イベント（nullable） |
| resource | 食パン, 鶏むね肉, 卵 等の食品（category=:grocery） |
| track | :track/actual のみ |
| target | nil（不要） |

### resource ツリー

```
grocery (category=:grocery)
├── grains
│   ├── 食パン (unit=枚) ★leaf
│   └── ご飯 (unit=g) ★leaf
├── meat
│   ├── 鶏むね肉 (unit=g) ★leaf
│   └── 豚ロース (unit=g) ★leaf
└── dairy
    ├── 卵 (unit=個) ★leaf
    └── 牛乳 (unit=mL) ★leaf
```

### entry の例

```clojure
;; 食品購入（6枚入りの食パン）
(xt/submit-tx node
  [[::xt/put {:xt/id (random-uuid)
              :entry/event ev1 :entry/owner me :entry/resource bread-id
              :entry/track :track/actual :entry/delta 6M}
    #inst "2025-05-15T10:00"]])

;; 昼食（12:00に食べたが19:00に記録）
(xt/submit-tx node
  [[::xt/put {:xt/id (random-uuid)
              :entry/event ev2 :entry/owner me :entry/resource bread-id
              :entry/activity lunch-id :entry/track :track/actual :entry/delta -1M}
    #inst "2025-05-15T12:00"]])
;; → tx-time は 19:00 が自動記録
```

### 栄養素の導出（拡張ドキュメント）

```clojure
;; food-nutrition-profile ドキュメント
{:xt/id (random-uuid)
 :fnp/resource bread-id
 :fnp/nutrient "protein"
 :fnp/factor 2.7}  ;; 1枚あたり 2.7g

;; 1日の栄養摂取クエリ
(xt/q (xt/db node)
  '{:find [?nutrient (sum ?intake)]
    :where [[?e :entry/delta ?delta]
            [(< ?delta 0)]
            [?e :entry/resource ?rid]
            [(get-start-valid-time ?e) ?vt]
            [(>= ?vt #inst "2025-05-15")]
            [(< ?vt #inst "2025-05-16")]
            [?fnp :fnp/resource ?rid]
            [?fnp :fnp/nutrient ?nutrient]
            [?fnp :fnp/factor ?factor]
            [(* (Math/abs ?delta) ?factor) ?intake]]})
```

### 設計上のポイント

- entry は食品単位で記録する。栄養素はクエリ時に導出する
- 食品の balance = 在庫（ストック）。残高管理が有意味
- 栄養素に残高管理は不要。期間集計（1日の摂取量）が主要な関心

---

## UC2. 個人の収支管理

収入・支出を記録し、月次予算と比較する。

### resource ツリーと track

```
収入
├── 給与 ★leaf         tracks: #{:track/actual}
└── 副収入 ★leaf       tracks: #{:track/actual}
支出
├── 食費 ★leaf         tracks: #{:track/actual :track/monthly-budget}
├── 家賃 ★leaf         tracks: #{:track/actual :track/monthly-budget}
└── 光熱費 ★leaf       tracks: #{:track/actual :track/monthly-budget}
```

### 予算 vs 実績の比較

```clojure
(xt/q (xt/db node)
  '{:find [?rname ?track (sum ?delta)]
    :where [[?e :entry/resource ?rid]
            [?e :entry/track ?track]
            [?e :entry/delta ?delta]
            [(get-start-valid-time ?e) ?vt]
            [(>= ?vt #inst "2025-05-01")]
            [(< ?vt #inst "2025-06-01")]
            [?rid :resource/name ?rname]]})
;; => [["食費" :track/actual -28000M]
;;     ["食費" :track/monthly-budget -30000M]
;;     ...]
```

### 予算の訂正

```clojure
;; 5月の食費予算を 30,000 → 35,000 に修正（同一 ID で新バージョン）
(xt/submit-tx node
  [[::xt/put
    {:xt/id budget-entry-id
     :entry/event ev :entry/owner me :entry/resource food-id
     :entry/track :track/monthly-budget
     :entry/delta -35000M}
    #inst "2025-05-01"]])
;; → tx-time に旧値 (-30000) が自動保存
```

---

## UC3. 会計（B/S + P/L）

資産・負債・純資産・収益・費用の全5分類を追跡する。

### resource ツリー

```
monetary (category=:monetary, unit=JPY)
├── revenue                    ← 中間ノード = 分類
│   └── 純売上高 ★leaf
├── expense
│   ├── 外注仕入 ★leaf
│   └── 一般管理費 ★leaf
├── asset
│   ├── 現金 ★leaf
│   ├── 銀行預金 ★leaf
│   └── 売掛金 ★leaf
├── liability
│   └── 未払費用 ★leaf
└── equity
    └── 純資産 ★leaf
labor (category=:labor)
├── hours (unit=h) ★leaf       ← 対象メンバーは attrs で記録
└── person-months (unit=PM) ★leaf
```

### 日常取引の例

```clojure
;; 売上計上
(let [ev-id (random-uuid)]
  (xt/submit-tx node
    [[::xt/put {:xt/id ev-id :event/description "売上計上"}]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner dept-id :entry/resource net-sales-id
                :entry/track :track/actual :entry/delta 100000M}
      #inst "2025-05-15"]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner dept-id :entry/resource ar-id
                :entry/track :track/actual :entry/delta 100000M}
      #inst "2025-05-15"]]))

;; 外注費支払
(let [ev-id (random-uuid)]
  (xt/submit-tx node
    [[::xt/put {:xt/id ev-id :event/description "外注費支払"}]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner dept-id :entry/resource outsource-id
                :entry/track :track/actual :entry/delta 50000M}
      #inst "2025-05-15"]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner dept-id :entry/resource bank-id
                :entry/track :track/actual :entry/delta -50000M}
      #inst "2025-05-15"]]))
```

### 設計上のポイント

- 貸借の整合性はコアスキーマでは強制しない。拡張クエリで対応
- 1つの event が P/L + B/S + 労務を横断して entry を生成する。これが resource 統合の利点

---

## UC4. クロスドメイン: 食品購入 × 会計

1つの event が monetary と grocery を横断する:

```clojure
(let [ev-id (random-uuid)]
  (xt/submit-tx node
    [[::xt/put {:xt/id ev-id :event/description "スーパーで食品購入"}]
     ;; monetary entries
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner me :entry/resource food-expense-id
                :entry/track :track/actual :entry/delta 3000M}
      #inst "2025-05-15T10:00"]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner me :entry/resource credit-payable-id
                :entry/track :track/actual :entry/delta 3000M}
      #inst "2025-05-15T10:00"]
     ;; grocery entries
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner me :entry/resource bread-id
                :entry/track :track/actual :entry/delta 6M}
      #inst "2025-05-15T10:00"]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner me :entry/resource chicken-id
                :entry/track :track/actual :entry/delta 500M}
      #inst "2025-05-15T10:00"]
     [::xt/put {:xt/id (random-uuid) :entry/event ev-id
                :entry/owner me :entry/resource egg-id
                :entry/track :track/actual :entry/delta 10M}
      #inst "2025-05-15T10:00"]]))
```

栄養素は food-nutrition-profile 経由でクエリ時に導出。

---

## まとめ

```
┌──────────────────────────────────────────────────┐
│                  resource-ledger                   │
│                                                    │
│  event ──1:N──> entry ──集計──> balance            │
│                  │              period-sum          │
│            ┌─────┼─────┐      track比較           │
│            ↓     ↓     ↓                          │
│         owner activity resource                    │
│         (tree) (tree)   (tree)                     │
│                           │                        │
│                     :resource/tracks                │
│                           │                        │
│                     track-master                    │
│                                                    │
│  valid-time: 帰属時点（::xt/put 時に指定）         │
│  tx-time: 記録時点（XTDB 自動、不変）              │
│  track: resource別に定義（actual は必須）           │
│                                                    │
│  技術スタック:                                      │
│    XTDB v1 + Biff + PostgreSQL (JDBC)              │
│    Datalog / Clojure / Malli                       │
└──────────────────────────────────────────────────┘
```

| 本質 | コメント |
|------|----------|
| 変動台帳 | 残高・期間集計は entry の SUM。訂正は ::xt/put で新バージョン |
| 多次元交点 | 誰が × 何のために × いつ × 何のリソース |
| resource別トラック | 記録文脈は resource ごとに定義。すべての entry は事実 |
| 階層集計 | ドリルダウン可能な木構造 |
| 統一リソース | 金額も食品も時間も同じ構造で記録 |
| bi-temporal | valid-time（業務時間）+ tx-time（監査）。XTDB v1 がネイティブに保証 |

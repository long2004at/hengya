# sqlite-vec 集成与 Dart 契约（检索加速层定稿）

日期：2026-09-06 ｜ 状态：已落地（本 commit）｜ 范围：automation/server-pipeline 检索链 + Phase 4 Dart 移植契约

## 0. 结论速览

- **形态**：`vec_chunks` 为**普通表**（`WITHOUT ROWID`），存 int8 量化向量的 **float32 归一化镜像**（BLOB）；检索侧用 sqlite-vec **标量距离函数**（`vec_distance_cosine` 优先，`vec_distance_L2` 退化）做**全表扫描**，Python 侧后置 subject/source_type 过滤。
- **为什么不用 vec0 虚表 KNN**：① KNN MATCH 的 `k` 上限 4096 < 全库 6954 行，融合需要**全量** cos dict（`all_ids = lex ∪ vec`），截断即破坏等价；② 实测虚表逐行物化 v 达 **19.1~24.5 s/全扫**（架构为 KNN 优化，全扫走 shadow 表逐行取回）——比 Python 流式还慢 40 倍。
- **性能**：Python 流式 494.2 ms/查询 → vec0 距离全扫 **101.6 ms/查询**（≈4.9x）；无过滤全扫单次 ~116ms，subject 过滤形态 ~72ms。
- **等价性**：8 试对拍 keys 全等、max|Δcos| = 1.0e-07 ~ 3.5e-07（float32 舍入量级，门槛 5e-4）；真库 validate 两态计数逐字对齐（rerank off：18/20、6/8、4/4@0.306；rerank on：20/21、7/8、4/4）；run.py --self-test 79/79。

## 1. sqlite-vec 0.1.9 能力矩阵（真库实测，2026-09-06）

| 能力 | 实测结果 |
|---|---|
| `vec_distance_cosine` / `vec_distance_L2` 标量函数 | ✓ 存在（另有 L1/hamming、vec_normalize、vec_f32/int8、vec_to_json、vec_length、vec_slice 等） |
| 标量函数参数格式 | BLOB（float32 LE）✓、JSON 字符串 ✓；**JSON 慢约 18 倍**（2284ms vs 126ms/全扫）→ 固定优先 BLOB |
| `CREATE ... distance_metric=cosine`（vec0 虚表建表选项） | ✗ 不支持 |
| KNN MATCH `k` 上限 | **4096**（6954 行报 `k value in knn query too large ... limit is 4096`） |
| int8[N] 列裸 BLOB 插入 | ✗ 会被误解析为 float32（勿用） |
| vec0 虚表全扫物化 v | **19.1~24.5 s/6954 行**（行迭代仅 12ms，物化才是瓶颈） |
| 普通 float32 BLOB 表 + 标量函数全扫 | ✓ **116ms/6954 行**（cosine 或 L2 几乎同速） |
| 语义对拍 | `1 - vec_distance_cosine(v, q̂)` vs 流式 `dot(q,ints)/(‖q‖·‖ints‖)`：Δ ~1e-08（逐行实测 1.2e-08 ~ 4.0e-08） |

**版本锁 0.1.9（pre-v1 警示）**：sqlite-vec 尚未发 1.0，vec0 虚表内部格式（shadow 表布局）与能力面随时可能变化。**本契约只依赖「普通表 + 标量距离函数」这层最小耦合**，不依赖虚表内部实现；升级版本时只需重跑 §5 等价性验收。

## 2. 存储契约（DDL 与格式）

```sql
-- corpus.db 内（sc.vec0_rebuild 维护，ingest 收尾自动重建）
CREATE TABLE vec_chunks(chunk_id TEXT PRIMARY KEY, v BLOB NOT NULL) WITHOUT ROWID;
-- meta 键：vec0_dim（使用依据与安全闩）/ vec0_version / vec0_rows
```

- `v` = 该 chunk int8 量化向量的**归一化 float32 镜像**：`n_i = int_i / ‖ints‖`，`struct.pack("<1024f", *n)`（小端 float32，4096 字节/行）。
- **恒等性依据**：int8 整数值在 float32 全精度无损；量化 `scale` 全库统一、余弦对 scale 免疫（不参与）；故 `dot(q̂, n) ≡ dot(q,ints)/(‖q‖·‖ints‖)`，与流式 int8 口径数学恒等（差仅 float32 舍入）。
- 零向量（‖ints‖=0）双侧同 skip；`vectors` 表存在维度不齐（len(vec)≠dim）行 → 重建整体拒绝（删表返回原因），绝不留半成品。
- 行集口径：`vectors v JOIN chunks c ON c.chunk_id=v.chunk_id`（与检索流式 JOIN 同口径），全库 6954 行 ≈ 28.5 MB。

## 3. 检索契约（search_corpus.py：`_vector_scan_vec0`）

- SQL 形态：`SELECT chunk_id, vec_distance_cosine(v, ?) FROM vec_chunks`（参数 = 查询归一化 float32 BLOB `struct.pack("<1024f", *qhat)`）；探测级联 `cosine→L2 × blob→json`（模块级缓存 `_VEC0_DIST_FN`，进程内一次）。
- 换算：cosine → `cos = 1 - d`；L2 → `cos = 1 - d²/2`（存储与查询双方归一化）；clamp [0,1] 与流式同口径。
- subject/source_type 过滤在 Python 侧后置（keep-set 查 `chunks` 表，与流式 JOIN 同口径）。
- **回退链（行为逐字等价的兜底）**：`VEC0=off` 显式关 → 流式；表缺失 / meta 无 `vec0_dim` / 查询维度 < 库维度 / 扩展不可加载 / 距离函数缺失 → note + 流式。任何回退只影响速度，不影响结果。
- 三态开关语义仿 RERANK：CLI `--vec0` > env `VEC0` > 内置默认 **on**。

## 4. 重建 / 回填（幂等）

```
python automation/server-pipeline/ingest_embeddings.py --db content/corpus/corpus.db --rebuild-vec0
# 纯本地零 API；真库实测 6954 行 1.8s（虚表时代 14s）
```

- 幂等：入口先删 meta 安全闩（vec0_dim 等）再 DROP 旧表——中途任何失败都不会留下「可被检索端使用」的半成品。
- **顺序教训（R13）**：扩展加载必须**先于** DROP——旧 `vec_chunks` 若为 vec0 虚表，DROP 需模块在场（虚表 xDestroy 走模块回调），否则 `no such module: vec0` 被 `except: pass` 静默吞掉 → 后续 CREATE 撞 `table already exists`。未加载扩展时连对虚表的 `count(*)` 都会报错。

## 5. 等价性与性能证据（2026-09-06 真库）

| 项 | 结果 |
|---|---|
| 探针③ 8 试对拍（4 无过滤 + 4 subject） | 8/8 OK：keys 全等（6954 / oms 860 / endo 637 / exam 906 / patho 587），max\|Δcos\| 1.01e-07~3.48e-07，vec0 路径 notes 实证（含「距离全扫」、无「回退」字样） |
| 耗时 | Python 494.2 ms/q vs vec0 101.6 ms/q（8 查询均值；单次全扫 ~116ms） |
| validate rerank off（VEC0 on） | A top1 18/27（67%）、top3 20/27（74%）；B 6/8（75%）；C 4/4，fake max **0.306** —— 与 vec0-off 基线**逐字一致** |
| validate rerank on（VEC0 on） | A top1 20/27（74%）、top3 21/27（78%）；B 7/8（88%）；C 4/4，fake max 0.306（基线 0.293 —— 重排跨次打分抖动，rank1 分数非单调实证重排生效，两值均 < 0.32，门不受影响） |
| run.py --self-test | 79/79（合成库 ingest 自动建 vec0，检索自动走新路径） |
| 重建 | 6954 行 float[1024]、序列化 BLOB、跳过 0、1.8s |

## 6. Dart / Phase 4 契约

**普通表方案对 Dart 极友好：不需要任何虚表模块，甚至不需要 sqlite-vec 扩展。**

1. 读 `vec_chunks`：`SELECT chunk_id, v FROM vec_chunks` → `Float32List`（`Uint8List.sublistView(blob).buffer` 小端，package:sqlite3 直接取 BLOB）。
2. 查询侧：API 嵌入 → 截断至 `meta.vec0_dim`（1024）→ 归一化 q̂。
3. 余弦：`cos = Σ q̂ᵢ·vᵢ`（Float32List 点积，clamp [0,1]）——与 `vec_distance_cosine` 换算结果在 float 舍入内一致；6954×1024 规模纯 Dart 点积预计 ~20-50ms，量级可接受（可后续优化为 Isolate）。
4. 若想复用 C 速度：Android 侧 `sqlite3_flutter_libs` + sqlite-vec 官方发布 `vec0.so`（`sqlite_vec.loadable_path()` 对应平台产物），加载后用与 Python 相同的 SQL（`vec_distance_cosine(v, ?)` 参数 float32 BLOB）。
5. 回退语义同 §3：表缺失 / `meta.vec0_dim` 缺失 / 维度不符 → 逐行 int8 流式解码（`vectors.vec`，`x̂ = int8 × scale` 不参与，直接整数点积），行为等价。
6. 契约常量：`VEC0_TABLE="vec_chunks"`、`VEC0_META_DIM="vec0_dim"`、默认 on、`VEC0=on|off` 三态。
7. **App 配置已就绪的接口**：AI 配置 `reranker.baseUrl/model/apiKey`（901212d）与检索开关无耦合；端上不建索引、不做 ingest 重建（库直接拷贝迁移，镜像随 corpus.db 走）。

## 7. 探针与验收方法论（复用备忘）

- 能力探针：`pragma_function_list WHERE name LIKE 'vec%'` 列函数 → 逐组合 `SELECT <fn>(v,?) FROM vec_chunks LIMIT 1` 试错 → 语义对拍（Python 算 cos_py vs `1-d`）→ 全表计时。见 `.snow/tmp/probe_vec_func.py` / `probe_vec_func2.py`。
- 等价探针（`probe_vec0_equiv.py`）：**必须断言「真走 vec0」**——收集 notes 验证含「距离全扫」且无「回退」字样，并要求 max|Δcos| 非零（全零 = 两路同径假阳性，2026-09-06 上半场的教训）。
- validate 复跑口径：`--k 3 --weights-list "0.4,0.6" --low-score-floor 0.32 --rerank off|on`（floor 0.32 须显式传参，`DEFAULT_LOW_FLOOR=0.30`）；VEC0 走 env 默认 on，off 态用 `$env:VEC0='off'`。

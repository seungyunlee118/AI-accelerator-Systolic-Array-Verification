# SA-GEMM 검증 계획 (vplan) v1.0 — 한국어판 (담당: Seungyun Lee)

> 공부용 번역본이에요. **기준 문서는 영어판 [`docs/vplan.md`](../vplan.md)**이고, 스펙은 v0.4를 기준으로 해요.

이 문서를 읽는 법
- §3은 모든 기능을 표 하나에 모아 둔 목차예요. §4는 어려운 기능만 자세히 설명해요.
- 자세히 설명한 기능은 모두 다섯 가지 질문에 답해요:
  1. **무엇이 참이어야 하나** (requirement, 요구사항)
  2. **무엇이 깨질 수 있나** (버그 가설)
  3. **그 상황을 어떻게 만드나** (stimulus, 자극)
  4. **맞는지 어떻게 아나** (checker, 검사기)
  5. **실제로 실행됐다는 걸 어떻게 증명하나** (coverage, 커버리지)
- 검사기는 `CHK-xx`(§5), 커버그룹은 `CG-xx`(§6), 테스트는 §7에 있어요.
- 우선순위: **P0** = sign-off(검증 완료 선언) 전에 반드시 끝내야 함, **P1** = 끝내는 게 좋음, **P2** = 여유 있으면.

## 1. 범위
- **포함:** `spec.md`에 정의된 `sa_top` 블록 전체. CSR 블록, 컨트롤러, DMA(AXI4 master), A/B 버퍼, PE 어레이, 출력단,
  인터럽트, 에러, 리셋. `ARRAY_N`은 먼저 4로 하고 그다음 8로 해요.
- **제외:** 게이트 레벨 시뮬레이션, 전력, 타이밍, CYCLES 카운터가 말이 되는지 확인하는 것 이상의 성능 목표,
  2^32를 넘어가는 주소 wrap-around(스펙 §5에서 정의하지 않음), 여러 클럭 도메인(설계에 클럭이 하나뿐).

## 2. 테스트벤치 구조
```
                      ┌──────────────────────── uvm_env ─────────────────────────┐
  test ─► virtual     │  axil_agent (active, CPU 역할) ─► RAL 모델 + predictor    │
          sequence ──►│        │ AXI4-Lite                                         │
                      │        ▼                                                   │
                      │   ┌───────── DUT sa_top ─────────┐   AXI4                  │
                      │   │ CSR ─► ctrl ─► DMA ──────────┼──────► axi_mem_agent    │
                      │   │        A/B buf ─► PE ─► outq │       (반응형 slave)    │
                      │   └──────────── irq ─────────────┘       + 메모리 모델     │
                      │                                                            │
                      │  job_scoreboard: START 때 설정 복사, golden GEMM +         │
                      │      requant 모델, 끝날 때 결과와 "다른 곳에 안 썼는지" 검사 │
                      │  dma_checker: 주소가 올바른지, outstanding/ID 규칙         │
                      │  커버리지 수집기 (CG-01..CG-09)                            │
                      └────────────────────────────────────────────────────────────┘
  tb_top: 클럭, 리셋, 인터페이스, AXI 포트 두 개와 CSR 블록에 bind한 SVA
```

| 구성요소 | 역할 |
|---|---|
| `axil_agent` (active) | **CPU 역할.** AXI4-Lite 읽기/쓰기를 보내요. AW/W 순서, WSTRB, B/R back-pressure(응답을 늦게 받기)를 조절할 수 있어요. AXI4-Lite 프로젝트 코드를 재사용하되, 핸드셰이크 버그와 `bus2reg` 응답 무시 버그를 고쳐서 써요. |
| RAL 모델 + explicit predictor | 레지스터 15개를 `uvm_reg`로 모델링해요(W1C, RO, 쓰기 전용 START 포함). 시퀀스는 `reg.write()/read()`로 레지스터에 접근하고, predictor가 AXI4-Lite monitor를 보고 mirror(예상값)를 최신으로 유지해요. |
| `axi_mem_agent` (반응형 slave) | **메모리 역할.** 바이트 단위 메모리(AXI4-Full 프로젝트의 레퍼런스 모델 재사용)가 DUT의 AR/AW/W 요청에 응답해요. 응답 지연, ready back-pressure, ID 간 순서 바꾸기, beat 섞기, RRESP/BRESP 에러 주입을 조절할 수 있어요. |
| `job_scoreboard` | START 때 설정값과 메모리의 A/B 데이터를 복사해 둬요. 작업이 끝나면 golden model로 예상 C를 계산해서 모든 C 원소를 비교하고, C 밖의 메모리가 그대로인지(sentinel) 확인해요. BUSY, ERR_CODE, IRQ_STATUS, CYCLES 동작도 예측해서 검사해요. |
| Golden model | GEMM과 §7 출력단을 스펙 그대로 구현한 **SystemVerilog 클래스**(`longint` 64비트 계산). RTL과 코드를 하나도 공유하면 안 돼요. (DPI-C는 2026-10-21에 확인했는데, 학교 서버에 glibc-devel이 없어서 링크가 안 돼요: `ld: cannot find crti.o, -lrt, -lm`.) |
| `dma_checker` | AXI4 포트를 지켜봐요. 모든 AR은 올바른 A/B 행 범위 안에 있어야 하고, WSTRB로 켜진 쓰기 바이트는 모두 C 원소여야 하고, 읽기 ID 규칙이 지켜져야 해요. |
| SVA | AXI4 프로토콜(`axi4_sva` 재사용, `uvm_error`로 보고), DMA 전용 규칙, AXI4-Lite 프로토콜, `irq` 일관성. |
| Virtual sequence | `job_vseq`: 메모리 채우기(backdoor) → RAL로 레지스터 설정 → 시작 → `irq`를 기다리거나 `IRQ_STATUS` polling → 인터럽트 지우기. 다른 vseq들은 이 위에 에러, 리셋, 레지스터 접근을 얹어요. |

## 3. 기능 목록
| ID | 스펙 § | 기능 | P | 검사기 | 커버리지 | 테스트 |
|---|---|---|---|---|---|---|
| **CSR** | | | | | | |
| F-CSR-01 | 4 | 모든 레지스터가 리셋값을 가짐. VERSION = 0x5341_0002 | P0 | CHK-07 | CG-01 | `csr_reset_test` |
| F-CSR-02 | 4 | RW 레지스터는 쓸 수 있는 비트만 저장, 안 쓰는 비트는 0으로 읽힘 | P0 | CHK-07 | CG-01 | `csr_rw_test` |
| F-CSR-03 | 3, 4 | 바이트 strobe: WSTRB=1인 바이트만 바뀜 | P1 | CHK-07 | CG-01 | `csr_rw_test` |
| F-CSR-04 | 3 | AW와 W가 어떤 순서로 와도 받음. B/R back-pressure도 처리 | P0 | CHK-07, CHK-05 | CG-01 | `csr_rw_test` |
| F-CSR-05 | 4 | 없는 주소는 SLVERR이고 부작용 없음. RO 쓰기는 무시하고 OKAY. 주소 [31:8], [1:0]은 무시 | P0 | CHK-07 | CG-01 | `csr_access_test` |
| F-CSR-06 | 4 | START는 wstrb[0]=1일 때만 동작, 읽으면 0, BUSY 중에는 무시 | P0 | CHK-09 | CG-07 | `b2b_jobs_test` |
| F-CSR-07 | 4 | BUSY 중 설정 변경이 진행 중인 작업에 영향 없음 | P0 | CHK-01, CHK-09 | CG-07 | `b2b_jobs_test` |
| F-CSR-08 | 4 | IRQ_STATUS는 기록이 유지되는 W1C. irq = (IRQ_STATUS AND IRQ_EN)의 OR. 같은 클럭에 이벤트와 클리어가 겹치면 이벤트가 이김 | P0 | CHK-07, CHK-08 | CG-01 | `csr_irq_test` |
| **데이터 경로** | | | | | | |
| F-DP-01 | 6 | 1~64 범위의 모든 M, N, K에서 C = A × B가 정확함 | P0 | CHK-01 | CG-02 | `gemm_rand_test`, `gemm_dim_test` |
| F-DP-02 | 5, 6.1 | 가장자리 타일: 모든 C 원소를 쓰고, C 밖에는 아무것도 안 씀 | P0 | CHK-01, CHK-02, CHK-03 | CG-02, CG-05 | `gemm_edge_test` |
| F-DP-03 | 5 | stride: 행 사이 빈 공간(gap), A/B stride가 행보다 작은 경우(겹침) | P1 | CHK-01, CHK-04 | CG-02 | `gemm_stride_test` |
| F-DP-04 | 6 | 극단적 입력(−128 × −128을 K=64번 더하기)에서도 overflow 없음 | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| F-DP-05 | 6 | 연속 작업: 이전 작업의 상태가 다음 작업에 남지 않음 | P0 | CHK-01, CHK-09 | CG-07 | `b2b_jobs_test` |
| F-DP-06 | 6 | 완료: 마지막 B 응답을 받은 뒤에만 BUSY가 내려가고 DONE이 켜짐. CYCLES 갱신 | P0 | CHK-09 | CG-07 | 모든 작업 테스트 |
| **DMA** | | | | | | |
| F-DMA-01 | 6.1 | AXI4 프로토콜: READY까지 VALID 유지, 대기 중 payload 고정, LAST 위치, X 없음 | P0 | CHK-05 | — | 모든 테스트 |
| F-DMA-02 | 6.1 | 버스트 모양: beat당 8B, INCR, 최대 8 beat, 4KB 경계를 넘지 않음 | P0 | CHK-05 | CG-04 | `dma_4k_test` |
| F-DMA-03 | 6.1 | 각 행 읽기가 필요한 바이트를 모두 포함, 초과 읽기는 최대 7바이트, 그 외는 안 읽음 | P0 | CHK-04 | CG-04 | `gemm_rand_test` |
| F-DMA-04 | 6.1 | outstanding 읽기 최대 4개, ARID 0~3은 서로 다름, RLAST 이후에만 ID 재사용 | P0 | CHK-06 | CG-04 | `dma_ooo_test` |
| F-DMA-05 | 6.1 | 순서 바뀜/섞인 R 데이터가 버퍼의 올바른 자리에 들어감 | P0 | CHK-01, CHK-06 | CG-04 | `dma_ooo_test` |
| F-DMA-06 | 6.1 | 쓰기: 한 번에 1개, AWID 0, AW가 첫 W보다 늦지 않음, WSTRB는 C 바이트에만 | P0 | CHK-03, CHK-06 | CG-05 | `gemm_edge_test` |
| F-DMA-07 | 6.1 | 모든 채널에 랜덤하고 긴 back-pressure를 줘도 문제없음 | P0 | CHK-01, CHK-05 | CG-04, CG-05 | `dma_backpressure_test` |
| **출력단** | | | | | | |
| F-OUT-01 | 7 | INT32 출력, ReLU 켜고 끄기 | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| F-OUT-02 | 7 | requant: SCALE과 SHIFT 전체 범위, 동률은 +무한대 쪽으로 반올림 | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| F-OUT-03 | 7 | −128과 127에서 포화, ReLU는 자르기 전에 적용 | P0 | CHK-01 | CG-03 | `gemm_quant_test` |
| **에러** | | | | | | |
| F-ERR-01 | 8 | BAD_DIM: 버스 트래픽 없음, BUSY 안 켜짐, ERR_CODE 1, BAD_ADDR보다 우선 | P0 | CHK-09 | CG-06 | `err_cfg_test` |
| F-ERR-02 | 8 | BAD_ADDR: 각 base/stride가 8의 배수가 아닌 경우, 모드별 C_STRIDE가 E×N보다 작은 경우 | P0 | CHK-09 | CG-06 | `err_cfg_test` |
| F-ERR-03 | 8 | RD_ERR: 새 버스트 중단, 진행 중인 읽기를 모두 마무리한 뒤 ERR로 종료 | P0 | CHK-10, CHK-09 | CG-06 | `err_bus_test` |
| F-ERR-04 | 8 | WR_ERR: 쓰기 쪽에서 같은 규칙 | P0 | CHK-10, CHK-09 | CG-06 | `err_bus_test` |
| F-ERR-05 | 6, 8 | 어떤 에러 뒤에도 다음 작업은 성공. DONE과 ERR이 동시에 켜지지 않음 | P0 | CHK-01, CHK-09 | CG-06 | `err_cfg_test`, `err_bus_test` |
| **리셋** | | | | | | |
| F-RST-01 | 9 | 대기 중 리셋하면 모든 레지스터가 리셋값으로 | P0 | CHK-07 | CG-08 | `csr_reset_test` |
| F-RST-02 | 9 | 작업 중(읽기, 계산, 쓰기) 리셋하면 모든 valid가 내려가고, 다음 작업은 정상 | P0 | CHK-11, CHK-01 | CG-08 | `reset_midjob_test` |

## 4. 기능 상세 (어려운 것들)

### F-ERR-01 — 잘못된 크기 (스펙 §6 2단계, §8)
- **요구사항:** M, N, K 중 하나가 0이거나 64보다 큰 상태에서 START가 받아들여지면,
  BUSY는 한 번도 켜지지 않고, AXI master 트래픽도 없고, `ERR_CODE = 1`, `IRQ_STATUS.ERR = 1`, `CYCLES = 0`으로 작업이 끝나요.
  BAD_DIM이 BAD_ADDR보다 우선이에요.
- **깨질 수 있는 것:**
  - 경계값 실수(64를 거부하거나 65를 받아들임).
  - M, N, K 중 하나만 검사함.
  - 7비트 필드라 65~127도 쓸 수 있는데, 검사가 그보다 적은 비트만 볼 수 있음.
  - DMA가 일단 시작했다가 멈춰서, AR 요청이 일부 새어 나감.
  - 두 에러가 같이 있을 때 BAD_ADDR로 보고함.
  - 에러 상태가 남아서 다음 정상 작업이 실패하거나 ERR_CODE가 그대로 남음.
- **자극:** M, N, K 각각을 {0, 1, 64, 65, 127} 중에서 고르고 나머지 둘은 정상값으로 DIMS에 써요.
  A_BASE를 8의 배수가 아니게 한 경우(우선순위 확인)도 반복해요. 매번 정상 작업 하나로 마무리해요.
- **검사기:** CHK-09가 ERR_CODE를 예측하고, START부터 ERR 이벤트까지 AR/AW 핸드셰이크가 0개인지, BUSY가 계속 0인지 확인해요.
  CHK-08이 `irq`를 확인해요.
- **커버리지:** CG-06의 `err_code` × `dim_class`, 그리고 `bad_dim × bad_addr`.

### F-DP-02 — 가장자리 타일과 쓰기 범위 (스펙 §5, §6.1 쓰기, §7)
- **요구사항:** 1~64 범위의 모든 M, N에 대해, r < M, c < N인 모든 C[r][c]를 원소 크기 E(4 또는 1)로 §7의 값으로 써요.
  그 외의 바이트는 하나도 쓰지 않아요.
- **깨질 수 있는 것:**
  - 마지막 타일 행/열의 padding(0으로 채운 가짜) 결과가 N이나 M을 넘어서 써짐.
  - 부분 beat의 WSTRB가 틀림(INT32 모드에서 N이 홀수, INT8 모드의 모든 N).
  - 행 주소를 C_STRIDE가 아니라 `E*N`으로 계산해서 행 사이 빈 공간을 덮어씀.
  - C 행 쓰기가 4KB 경계를 넘음.
- **자극:** M mod 4와 N mod 4의 모든 나머지 조합, K는 랜덤, REQ_EN 0과 1, C_STRIDE가 `E*N`과 같을 때와 클 때,
  C_BASE를 행이 4KB 경계에 걸리도록 배치.
- **검사기:**
  - CHK-02: START 전에 메모리 모델이 C 행, 빈 공간, C 앞뒤 64바이트를 특정 패턴(sentinel)으로 칠해 둬요.
    DONE 뒤에 C 원소가 아닌 바이트는 모두 그 패턴 그대로여야 해요.
  - CHK-03: beat마다, WSTRB로 켜진 바이트는 모두 C 원소의 바이트여야 해요. 끝에 가서 실패하는 대신 **틀린 beat를 그 순간 바로** 알려줘요.
  - CHK-01: 모든 C 원소가 golden model과 같아야 해요.
- **커버리지:** CG-02의 `m_mod4 × n_mod4 × req_en`, `c_gap`. CG-05의 WSTRB 모양. CG-04/05의 4KB 경계 넘기.

### F-DMA-04 / F-DMA-05 — outstanding, 순서 바뀜, 섞인 읽기 (스펙 §6.1)
이 프로젝트의 핵심이에요.
- **요구사항:**
  1. 동시에 진행 중인 읽기 버스트(AR은 받아들여졌고 RLAST는 아직)가 4개를 넘지 않아요.
  2. 진행 중인 버스트들은 서로 다른 ARID(0~3)를 가져요.
  3. ARID는 그 버스트의 RLAST를 받은 뒤에만 재사용해요.
  4. R beat는 ID 사이에서 어떤 순서로 와도 되고 beat 단위로 섞여 와도 되는데, 모든 beat가 A/B 버퍼의 올바른 행과 바이트에 들어가야 해요.
- **깨질 수 있는 것:**
  - ID 표(ID → 어느 행, 몇 번째 beat)에 잘못된 행을 저장하거나, beat 카운터를 ID별로 두지 않고 공유해서 섞여 온 beat가 엉뚱한 자리에 들어감.
  - ID를 RLAST가 아니라 첫 beat에서 반납해서 너무 일찍 재사용됨.
  - outstanding 카운터가 하나 어긋나서 5개가 되거나 3개에서 멈춤.
  - 응답이 순서대로 올 때만 동작함(다른 경우를 테스트한 적이 없어서 모름).
  - 4KB 경계에서 나눈 버스트를 하나로 취급해서, 뒤쪽 절반이 행의 시작 부분에 들어감.
  - 데드락: 4개가 진행 중일 때 빈 ID를 기다리는데, ID를 보낸 순서대로만 반납해서 순서가 바뀌어 끝난 버스트의 ID가 영원히 반납되지 않음.
- **자극:**
  - 메모리 응답기가 버스트마다 랜덤 지연(예: 20~200 클럭) 뒤에 데이터를 보내요. **지연이 길어야 DUT가 4개 동시 요청까지 도달**해요.
  - 순서 바꾸기 모드: 보낼 수 있는 버스트가 여러 개면 가장 오래된 것이 아니라 랜덤으로 골라요.
  - 섞기 모드: 준비된 버스트 중 랜덤으로 골라 한 beat씩 보내요.
  - 짧은 행렬(K ≤ 8, 행당 1 beat)과 긴 행렬(K = 64, 8 beat)을 둘 다 써서, 섞을 beat가 실제로 있게 해요.
- **검사기:**
  - CHK-01 (end-to-end): C가 golden model과 같아야 해요.
    **함정:** 두 행의 데이터가 같으면, 두 행을 바꿔 넣는 버그가 있어도 C는 맞게 나와요.
    그래서 **모든 행이 서로 다른 데이터**를 갖게 해야 해요(예: 첫 바이트에 행 번호 넣기). 안 그러면 이 버그는 안 보여요.
  - CHK-06 (AXI4 포트의 SVA): outstanding ≤ 4, 진행 중인 ID로 새 AR을 보내지 않음.
    이건 버스 자체의 규칙이라 assertion이 **바로 그 클럭에** 잡아요. scoreboard는 한참 뒤에 틀린 결과로만 보거나 아예 못 볼 수도 있어요.
  - CHK-04: 모든 AR이 올바른 행 범위 안에 있어야 해요.
- **커버리지 (CG-04):** AR 핸드셰이크 때의 outstanding 개수 {1,2,3,4}, 사용한 ARID {0,1,2,3},
  "오래된 버스트보다 먼저 끝난 버스트가 있었음"(순서 바뀜 발생), "한 버스트의 beat 사이에 다른 ID의 beat가 끼어들었음"(섞임 발생),
  outstanding = 4 × 순서 바뀜 교차, ARLEN {0, 1~6, 7}, 4KB에서 나뉜 행.

### F-OUT-02 / F-OUT-03 — requant 경계값 (스펙 §7)
- **요구사항:** 모든 원소의 출력이 §7 공식과 같아야 해요. SCALE을 곱하고, 2^SHIFT로 나누면서 동률은 +무한대 쪽으로 반올림하고,
  필요하면 ReLU를 적용하고, [−128, 127]로 자르기.
- **깨질 수 있는 것:** 동률을 +무한대 쪽이 아니라 0에서 먼 쪽으로 반올림함(음수 .5에서만 차이가 보임),
  SHIFT = 0 처리가 틀림, SCALE이 클 때 곱셈이 32비트를 넘어 overflow, ReLU를 자르기 뒤에 적용함,
  자르기 경계가 하나 어긋남(−129나 128이 새어 나옴).
- **자극:** 원하는 누산값이 나오도록 A/B 값을 골라요. K = 1이면 누산값은 그냥 `a × b`라서 정확한 값을 만들기 쉬워요
  (예: a = −3, b = 1, SHIFT = 1이면 −1.5 동률). K를 크게 하고 행을 같은 값으로 채우면 큰 누산값이 나와요.
  SCALE은 {0, 1, 2, 랜덤, 65535}, SHIFT는 {0, 1, 랜덤, 30, 31}로 훑어요.
- **검사기:** CHK-01. golden model은 스펙 공식으로 64비트 계산을 독립적으로 구현해요(`sa_outq.sv`를 절대 재사용하지 않음).
- **커버리지 (CG-03):** 원소별 결과 종류 {범위 안, 위로 잘림, 아래로 잘림, ReLU로 0}, 동률 {양수 동률, 음수 동률},
  SCALE과 SHIFT 구간, 결과 종류 × RELU_EN, 동률 × 부호.

### F-ERR-03 — 읽기가 진행 중일 때 읽기 에러 (스펙 §8)
- **요구사항:** RRESP 에러를 받은 뒤 새 AR을 보내지 않고, 진행 중인 버스트는 RLAST까지 모두 받은 다음,
  `ERR_CODE = 3`, `IRQ_STATUS.ERR = 1`로 BUSY가 내려가요.
- **깨질 수 있는 것:** DUT가 R beat를 더 이상 안 받아서(RREADY가 계속 0) 버스가 멈춤, 에러 뒤에 읽기를 더 보냄,
  진행 중인 버스트가 끝나기 전에 작업을 끝냄, ERR과 함께 DONE도 켜짐.
- **자극:** 읽기가 1~4개 진행 중일 때 랜덤 버스트의 랜덤 beat에 에러를 넣어요. 작업의 맨 처음 버스트와 맨 마지막 버스트에도 넣어요.
- **검사기:** CHK-10(첫 에러 응답 뒤에 AR 없음, 진행 중인 RLAST를 모두 받은 뒤에만 BUSY가 내려감), CHK-09(코드와 플래그), 멈춤 감시용 작업별 watchdog.
- **커버리지 (CG-06):** 에러가 난 단계 {A 읽기, B 읽기} × 에러 때의 outstanding 개수.

### F-RST-02 — 작업 도중 리셋 (스펙 §9)
- **요구사항:** 언제 리셋해도 모든 AXI valid가 내려가고, 레지스터가 리셋값으로 돌아가고, 리셋 뒤 다음 작업은 정상 동작해요.
- **깨질 수 있는 것:** 리셋 중에 valid가 1로 남음, ID 표의 오래된 항목이 리셋 뒤에도 남아서 다음 작업을 망침, CSR에 BUSY가 남음.
- **자극:** 각 단계(A 읽기, B 읽기, 계산, C 쓰기)에서 랜덤한 시점에 리셋해요. 메모리 쪽도 칩과 같이 리셋되니까
  메모리 모델은 리셋 때 대기 중인 요청을 모두 버려요. 그다음 정상 작업을 하나 돌려요.
- **검사기:** CHK-11(리셋 중 valid 없음), CHK-07(리셋값), 다음 작업에서 CHK-01.
- **커버리지 (CG-08):** 리셋 단계 × 리셋 때의 outstanding 읽기 개수.

## 5. 검사기와 assertion
| ID | 위치 | 검사 내용 |
|---|---|---|
| CHK-01 | job_scoreboard | 모든 C 원소가 golden GEMM + §7 출력단 결과와 같음 |
| CHK-02 | job_scoreboard + 메모리 모델 | 작업 뒤 C 원소 밖의 바이트(행 사이 빈 공간, 앞뒤 64B)가 sentinel 그대로임 |
| CHK-03 | 메모리 모델 (beat마다) | WSTRB로 켜진 모든 바이트가 현재 작업의 C 원소 바이트임 |
| CHK-04 | dma_checker | 모든 AR이 올바른 A/B 행 범위 안, 초과 읽기 최대 7바이트, 필요한 바이트는 모두 요청됨 |
| CHK-05 | SVA (`axi4_sva`와 AXI4-Lite SVA 재사용) | READY까지 VALID 유지, 대기 중 payload 고정, LAST 위치, 유효 신호에 X 없음, AxSIZE = 3, INCR, AxLEN ≤ 7, 4KB 경계 안 넘음 |
| CHK-06 | SVA (신규, DMA 규칙) | 읽기 outstanding ≤ 4, 진행 중인 ARID 재사용 금지, 쓰기는 최대 1개, AWID = 0, AW 전에 W beat 없음 |
| CHK-07 | RAL | 읽은 값이 mirror와 같음(W1C 예측과 리셋값 포함), 없는 주소에서만 정확히 SLVERR |
| CHK-08 | CSR 블록에 bind한 SVA | `irq`가 매 클럭 (IRQ_STATUS AND IRQ_EN)의 OR과 같음 |
| CHK-09 | job_scoreboard | 작업마다: 예상 ERR_CODE, DONE과 ERR 구분, 설정 에러에서 BUSY 안 켜짐과 버스 트래픽 0, 설정 에러면 CYCLES = 0이고 정상이면 > 0 |
| CHK-10 | SVA + job_scoreboard | 에러 응답 뒤 새 AR/AW 없음, 진행 중인 버스트가 모두 끝난 뒤에만 BUSY가 내려감 |
| CHK-11 | SVA | 리셋 중에는 모든 AXI valid가 0 |
| CHK-12 | test base | 작업별 watchdog과 UVM timeout으로 멈춤 감지 |

모든 SVA 실패는 `uvm_error`로 보고해서 테스트를 실패시켜요. (L1 캐시 프로젝트에서 `$error` assertion이 실패해도 테스트가 통과했던 교훈)

## 6. 커버리지 모델
| 커버그룹 | 샘플링 시점 | 커버포인트 / bin | 교차(cross) | 목표 |
|---|---|---|---|---|
| CG-01 csr | AXI4-Lite 접근마다 | 레지스터 × 접근(읽기, 쓰기), AW/W 순서 {AW 먼저, W 먼저, 동시}, WSTRB {전체, 부분}, 없는 주소, RO 쓰기, 이벤트와 같은 클럭의 W1C 클리어 | 레지스터 × 접근 | 100% |
| CG-02 job_cfg | START마다 | M, N, K 구간 {1, 2–3, 4, 5–7, 8, 9–63, 64}, M mod T, N mod T (T = ARRAY_N, 타일 크기: 가장자리 타일), C 빈 공간 {없음, 있음}, A/B stride {빈 공간, 딱 맞음, 겹침, 0} | m_mod_T × n_mod_T × req_en | 100% |
| CG-03 output | C 원소마다 | 결과 종류 {범위 안, 위로 잘림, 아래로 잘림, ReLU 0}, 동률 {양수, 음수}, SCALE {0, 1, 중간, 65535}, SHIFT {0, 1, 중간, 31}, REQ_EN, RELU_EN | 결과 종류 × relu_en, 동률 × req_en | 100% |
| CG-04 dma_read | AR마다 / 버스트 끝마다 | AR 때 outstanding {1,2,3,4}, ARID {0..3}, ARLEN {0, 1–6, 7}, 4KB 분할, 순서 바뀜 발생, 섞임 발생, RRESP 에러 | outstanding=4 × 순서 바뀜 | 100% |
| CG-05 dma_write | W beat마다 / B마다 | AWLEN, WSTRB 모양 {전체, 아래 절반, 위 절반, 1바이트, 기타}, BRESP 에러, 4KB 분할 | WSTRB 모양 × req_en | 100% |
| CG-06 errors | 작업 끝마다 | ERR_CODE {0..4}, 에러 단계 {설정, A 읽기, B 읽기, C 쓰기}, 에러 때 outstanding, BAD_DIM과 BAD_ADDR 동시 | err_code × 단계 | 100% |
| CG-07 job_flow | START마다 | BUSY 중 START, BUSY 중 설정 쓰기, 연속 작업, polling 완료 vs 인터럽트 완료 | — | 100% |
| CG-08 reset | 리셋마다 | 단계 {대기, A 읽기, B 읽기, 계산, C 쓰기}, 리셋 때 outstanding | 단계 × outstanding | 100% |
| CG-09 array (P2) | 작업마다 | ARRAY_N 4와 8 | — | 100% |

**구현.** `tb/cov/sa_csr_cov.svh` (CG-01), `sa_csr_race_cov.svh` (CG-01r, W1C 경쟁, CSR 테스트벤치),
`sa_top_cov.svh` (CG-02..09). 서버에 IMC가 없어서 Cadence 툴로는 여러 run의 covergroup 결과를 합칠 수 없어요.
그래서 각 collector가 같은 라벨로 `sa_cov_db`에도 bin을 세고, run마다 그 수를 파일로 내보내고(`+COV_DUMP`),
`sim/covmerge.py`가 regression의 통과한 run들을 합쳐요(`regress.py`가 실행). run이 끝날 때 이 수와 각 covergroup의
`get_inst_coverage()` 값을 비교해서, 다르면 테스트가 실패해요. 그래서 두 bin 목록이 몰래 어긋날 수 없어요.
도달할 수 없는 bin은 모델에서 `ignore_bins`로, 도달은 가능하지만 아직 목표가 아닌 bin은 이유와 함께 `sim/cov_waivers.txt`에 적어요.

### 6.1 Closure 기록
첫 병합 결과 (테스트 17개 x seed 4개): 98.0%, 구멍 7개.

| 구멍 | 진단 | 조치 |
|---|---|---|
| CG-01 `cp_alias` [1:0]만 더러움 | aliasing 테스트가 항상 [31:8]과 [1:0]을 같이 더럽혔음 | `csr_access_test`가 high만 / low만 / 둘 다를 돌아가며 사용 |
| CG-04 `x_ot_ooo` outstanding 1 x 순서 바뀜 | 불가능: 혼자 나간 버스트는 앞지를 이전 버스트가 없음 | `ignore_bins` |
| CG-05 `x_wstrb_mode` 상위 절반 x INT32 | 불가능: INT32 행은 8바이트 경계에서 시작하는 온전한 워드 | `ignore_bins` |
| CG-05 `cp_awlen` 3비트 이상, `x_wstrb_mode` full x INT8 | ARRAY_N = 8 (32 B / 8 B 타일 행)에서만 도달 | ARRAY_N = 8 빌드까지 waiver |
| CG-06 `x_rd_phase_inflight` A 로드 x 진행 중 1개 | 읽기 에러를 항상 느린 메모리(진행 중 4개)로 넣었음 | `err_bus_test`: 버스트 하나짜리 A, B 행렬 추가 |
| CG-08 `x_phase_inflight` B 로드 x 진행 중 2개 | 리셋을 단계만 겨냥했음 | `reset_midjob_test`가 진행 중 읽기 0..4개를 기다림 |

결과: 100% (waiver 3개, 모두 ARRAY_N = 8), seed 4개와 20개 모두.

6주차: ARRAY_N = 8 빌드가 세 개 모두 hit(4비트 쓰기, INT8 full beat 행, ARRAY_8)해서 waiver를 없앴어요.
CG-02는 이제 M, N을 빌드의 타일 크기로 나눈 나머지(8x8이면 0..7)로 나누고, `gemm_edge_test`가 모든 나머지 쌍을
다뤄요: 386 bin, 100%, waiver 없음.
도중에 self-check가 Xcelium은 `-cov_cgsample` (또는 `-coverage U`) 없이는 covergroup을 전혀 샘플링하지 않는다는 걸
찾았어요: 모든 covergroup이 0%를 보고했는데 bin 수는 그렇지 않았음.

## 7. 테스트 목록
| 테스트 | 목적 | 주요 기능 |
|---|---|---|
| `csr_reset_test` | `uvm_reg_hw_reset_seq` + 대기 중 리셋 | F-CSR-01, F-RST-01 |
| `csr_rw_test` | RAL bit-bash + 랜덤 WSTRB와 AW/W 순서 | F-CSR-02..04 |
| `csr_access_test` | 없는 주소, RO 쓰기, 주소 별칭(alias) | F-CSR-05 |
| `csr_irq_test` | W1C, enable 마스킹, 같은 클럭의 이벤트 vs 클리어 | F-CSR-08 |
| `gemm_smoke_test` | 4×4×4 작업 하나, 이상적인 메모리 (가장 먼저 돌릴 테스트) | F-DP-01 |
| `gemm_dim_test` | 크기 경계값 {1, 3, 4, 5, 63, 64} | F-DP-01 |
| `gemm_edge_test` | M/N의 모든 나머지, 두 출력 모드, sentinel 검사 | F-DP-02, F-DMA-06 |
| `gemm_stride_test` | 빈 공간 있는 stride와 겹치는 stride | F-DP-03 |
| `gemm_quant_test` | requant와 ReLU 경계값, 극단적 입력 | F-DP-04, F-OUT-01..03 |
| `gemm_rand_test` | 전부 랜덤 (커버리지를 주로 채우는 테스트) | 대부분 |
| `dma_ooo_test` | 긴 지연, 순서 바뀜, 섞인 응답 | F-DMA-04, F-DMA-05 |
| `dma_backpressure_test` | 모든 채널에 랜덤하고 긴 READY/VALID 지연 | F-DMA-07 |
| `dma_4k_test` | 4KB 경계를 넘는 행과 C 쓰기 | F-DMA-02 |
| `b2b_jobs_test` | 연속 작업, BUSY 중 START, BUSY 중 설정 쓰기 | F-CSR-06, F-CSR-07, F-DP-05 |
| `err_cfg_test` | BAD_DIM과 BAD_ADDR 훑기, 매번 정상 작업으로 마무리 | F-ERR-01, F-ERR-02, F-ERR-05 |
| `err_bus_test` | 읽기 진행 중 RRESP/BRESP 에러 | F-ERR-03..05 |
| `reset_midjob_test` | 각 작업 단계에서 리셋, 그다음 정상 작업 | F-RST-02 |

seed: 매일 돌리는 regression에서는 테스트마다 seed 4개 이상, sign-off 전에는 seed 20개.

### Formal 증명 (SymbiYosys, `formal/`)
시뮬레이션은 테스트가 우연히 만든 입력 순서만 확인하지만, 증명은 가능한 모든 입력 순서를 확인해요.
상태 공간이 작고 코너 케이스가 많은 제어 블록에 formal을 써요.

| 증명 | 블록 | 모든 입력 순서에 대해 증명하는 것 | 기능 | 상태 |
|---|---|---|---|---|
| `csr` | `sa_csr` | AXI4-Lite slave 프로토콜 (B/R은 받아갈 때까지 유지, 요청 뒤에만 응답, AW/W 순서 무관); offset별 OKAY/SLVERR; 모든 레지스터 읽기 값; byte lane별로 쓰기 가능한 비트만 쓰기; 같은 cycle의 clear보다 이벤트가 이기는 W1C; `irq`; START 펄스는 lane 0 필요 | F-CSR-02..05, F-CSR-06 (START 부분), F-CSR-08 | k-induction 통과; 버그 mutant 10/10 잡음, 안전한 변경 1개 증명 |
| `dma_rd` | `sa_dma_rd` (읽기 엔진) | 어떤 AXI4 메모리에 대해서도(ARREADY 타이밍, 응답 순서와 섞임, RRESP 모두 자유): AR 프로토콜과 버스트 모양(4 KB 포함); RLAST 전에 ARID 재사용 없음(outstanding ≤ 4); 모든 beat가 버스 주소 = 스펙 주소인 버퍼 칸에 기록됨; 에러 후 새 버스트 없음, 다 받은 뒤에만 done, err 보고; 모든 행의 모든 칸이 채워짐(64 x 64까지 모든 크기) | F-DMA-02..05, F-ERR-03 (읽기 쪽) | k-induction 통과 (~12초); 버그 mutant 9/9를 스펙 속성만으로 잡음 (helper 끔), 안전한 변경 2개 증명 |

DMA 증명을 풀 수 있게 만든 방법 (`formal/dma_rd/sa_dma_rd_props.svh`):
- 두 인자가 모두 자유로운 스펙 주소 `base + row * stride` 때문에 모든 솔버(yices, bitwuzla, boolector,
  abc pdr)가 10분 넘게 결과를 못 냈어요. 섀도 모델이 행이 한 칸 넘어갈 때마다 stride를 더해서 행 주소를 만들고,
  속성 P0이 행 카운터가 항상 1씩만 증가하는지 확인해요. 그러면 공식은 구성상 참이고, 솔버는 덧셈만 봐요.
- 완전성은 처음에 bounded 체크(3행, 40사이클)였는데 너무 느렸어요. 지금은 귀납 보조정리로 모든 크기에서 증명해요:
  어떤 칸의 버스트가 발행되면, 그 칸은 이미 쓰였거나 진행 중인 버스트가 아직 그 칸을 덮고 있어요.
- 안전한 mutant `safe_no_r_err_guard`는 1주차 질문(스모크 테스트로 못 잡은 RTL mutant, 손으로 동등하다고 주장했던 것)을
  해결해요: 증명이 실제로 동등함을 보여줘요.

## 8. Sign-off 기준 (검증 완료 조건)
- **Functional coverage:** P0 커버그룹은 모두 100%. P1은 100%이거나, 리뷰를 거친 waiver(예외 처리)가 있어야 함.
- **Code coverage:** statement와 branch ≥ 95%, toggle ≥ 90%. 빠진 부분은 모두 이유를 설명하거나 waiver 처리.
  **미해결 (툴):** Xcelium은 데이터베이스를 모으지만(`make CODECOV=1`), 읽거나 합치려면 IMC가 필요한데 서버에 없어요
  (2026-10-22 확인: `imc` 없음, `iccr` 폴더는 빈 껍데기, UCIS XML 출력 없음). IMC를 쓸 수 있을 때까지는
  functional coverage와 mutation 캠페인으로 테스트벤치의 충분함을 판단해요.
- **Regression:** 모든 테스트 × seed 20개가 UVM_ERROR 0, UVM_FATAL 0, SVA 실패 0으로 통과.
- **버그:** 열린 P0/P1 버그 없음. 고친 버그마다 수정 전 RTL에서는 실패하는 테스트가 있어야 함.
- **테스트벤치 품질:** mutation 캠페인에서 동작이 다른(non-equivalent) mutant를 95% 이상 잡음.
- **Formal:** 모든 증명이 PASS로 끝나야 함 (UNKNOWN은 안 됨). 모든 cover에 도달해야 하고 (vacuous 증명 아님),
  mutant 스크립트가 버그 mutant를 모두 잡아야 함.

### 8.1 Sign-off 검토 (2026-10-23)
| 기준 | 상태 | 근거 |
|---|---|---|
| Functional coverage | **충족** | CG-01..09의 386 bin 100%, 두 어레이 크기, waiver 없음 |
| Code coverage | **미해결 (툴)** | 데이터베이스는 수집됨(`make CODECOV=1`); 서버에 읽을 IMC가 없음 |
| Regression | **충족** | 테스트 17개 x seed 20개, 풀칩 테스트는 ARRAY_N 4와 8 모두: 600/600 통과 |
| 버그 | **충족** | RTL 버그 없음(`docs/bug_log.md`); 스펙 질문 6개 해결(§9) |
| 테스트벤치 품질 | **충족** | 시뮬레이션 mutant 16/16, ARRAY_N 4와 8 모두 (100% ≥ 95%) |
| Formal | **충족** | `csr`, `dma_rd`: k-induction 통과, cover 모두 도달, 버그 mutant 19/19, 안전한 변경 3개 증명 |

판정: ARRAY_N 4와 8에 대해 sign-off. 남은 항목은 code coverage 하나(툴 접근 문제).

## 9. 열린 질문 (설계자에게)
| # | 스펙 § | 질문 | 답 (설계자) | 상태 |
|---|---|---|---|---|
| Q1 | 6, 4 | 설정 에러일 때 BUSY가 한 번이라도 켜지나? 끝난 뒤 CYCLES는? | BUSY는 한 번도 켜지지 않고, CYCLES는 0. 스펙 v0.3 §6 2단계에 추가 | 해결 |
| Q2 | 6, 8 | 실패한 작업에서 DONE도 켜지나? | 아니요. DONE은 성공 때만, ERR은 실패 때만, 동시에 켜지지 않음. 스펙 v0.3 §6 5단계 | 해결 |
| Q3 | 5 | A_STRIDE < K(행이 겹침)도 허용되나? | 허용. 공식 그대로 읽음. 스펙 v0.3 §5 | 해결 |
| Q4 | 5 | 주소 범위가 2^32를 넘어가면? | 정의되지 않음. 소프트웨어가 하면 안 됨. TB는 모든 영역을 2^32 미만으로 제한. 스펙 v0.3 §5 | 해결 |
| Q5 | 9 | 작업 도중 리셋한 뒤에도 이전 R/B 응답이 올 수 있나? | 메모리 쪽도 칩과 같이 리셋되므로 오지 않음. TB 메모리 모델은 리셋 때 대기 중인 요청을 모두 버림. (DUT 규칙이 아니라 TB 가정) | 해결 |
| Q6 | 9 | `reset_midjob_test`가 두 상승 에지 사이에서 약 1 ns 동안만 리셋을 걸었음. DUT 플립플롭은 (비동기라서) 리셋됐지만, 메모리와 클럭 기반 관찰자들은 리셋을 못 봤고, 메모리가 DUT가 잊어버린 버스트의 데이터를 계속 보냄. 리셋 펄스의 최소 길이는? | `clk` 상승 에지 최소 두 번, 해제는 동기식. 스펙 v0.4 §9. 테스트는 이제 리셋을 에지 두 번 + 랜덤 추가 시간 동안 유지 | 해결 |

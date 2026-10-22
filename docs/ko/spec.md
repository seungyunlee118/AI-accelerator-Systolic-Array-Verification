# SA-GEMM: 시스톨릭 어레이 INT8 행렬곱 가속기 — 설계 스펙 v0.4 (한국어판)

> 공부용 번역본이에요. **기준 문서는 영어판 [`docs/spec.md`](../spec.md)**이고, 내용이 다르면 영어판이 맞아요.
> 처음 나오는 어려운 용어에는 괄호로 짧은 설명을 붙였어요.

개정 이력
| 버전 | 변경 내용 |
|------|-----------|
| 0.1 | 최초 버전: DMA 요청을 한 번에 하나만, INT32 출력 |
| 0.2 | 읽기 버스트 최대 4개 동시 진행, 응답 순서 바뀜/섞임(out-of-order/interleave) 허용, INT8 재양자화 출력(QCFG, QSCALE), ReLU 추가 |
| 0.3 | vplan 리뷰에서 나온 내용 명확화: 설정 에러 시 BUSY/CYCLES 동작, DONE과 ERR의 관계, 행이 겹치는 stride, 주소 범위 |
| 0.4 | 리셋: 최소 유지 시간과 동기 해제 (작업 도중 리셋 테스트에서 발견) |

## 1. 개요
SA-GEMM은 `C = A × B`를 계산해요. `A`는 M×K, `B`는 K×N 크기의 부호 있는 INT8 행렬이에요.
계산 결과는 부호 있는 INT32 행렬이고, 설정에 따라 INT8로 다시 줄여서(재양자화) 내보낼 수 있어요.

동작 흐름:
1. 소프트웨어(CPU)가 AXI4-Lite CSR 포트로 작업을 설정해요.
2. 가속기가 자기 AXI4 master 포트(DMA)로 메모리에서 `A`, `B`를 직접 읽어 와요.
3. 계산한 `C`를 같은 DMA로 메모리에 다시 써요.
4. 끝나면 인터럽트(irq)를 올려요.

```
 AXI4-Lite slave ──► CSR ──► 컨트롤러 FSM ──► DMA (AXI4 master) ◄──► 메모리
                                  │              │
                                  ▼              ▼
                     A/B 버퍼 ──► N×N output-stationary PE 어레이 ──► requant ──► C
                                                       irq ◄── 인터럽트 로직
```

## 2. 파라미터
| 이름 | 기본값 | 의미 |
|------|--------|------|
| `ARRAY_N` | 4 | PE 어레이 크기 ARRAY_N × ARRAY_N (최종 버전은 8) |
| `MAX_DIM` | 64 | M, N, K의 최댓값 |
| `DATA_W` | 8 | 입력 원소 비트 수 (부호 있음) |
| `ACC_W` | 32 | 누산기 비트 수 (부호 있음) |
| `AXI_DW` | 64 | AXI4 master 데이터 폭 (beat 하나 = 8바이트) |
| `MAX_RD_OT` | 4 | 동시에 진행할 수 있는 읽기 버스트 최대 개수 |

## 3. 인터페이스
- `clk`, `rst_n`: 클럭 하나, 비동기 active-low 리셋(0일 때 리셋).
- **AXI4-Lite slave** `s_axil_*`: 주소 32비트, 데이터 32비트. `wstrb`를 바이트 단위로 반영해요.
  방향마다 한 번에 하나의 요청만 처리하고, AW(주소)와 W(데이터)는 어느 쪽이 먼저 와도 돼요.
- **AXI4 master** `m_axi_*`: 주소 32비트, 데이터 64비트. 있는 신호:
  AW(`awid[3:0] awaddr awlen[7:0] awsize[2:0] awburst[1:0] awvalid awready`),
  W(`wdata wstrb[7:0] wlast wvalid wready`), B(`bid bresp bvalid bready`),
  AR(`arid[3:0] araddr arlen arsize arburst arvalid arready`),
  R(`rid[3:0] rdata rresp rlast rvalid rready`). cache/prot/lock/qos/region 신호는 없어요.
- `irq`: 1이면 인터럽트 발생. `irq = |(IRQ_STATUS & IRQ_EN)`
  (IRQ_STATUS와 IRQ_EN에서 같은 자리가 둘 다 1인 비트가 하나라도 있으면 1).

## 4. CSR 맵 (AXI4-Lite, 32비트 레지스터)
| 주소 | 이름 | 비트 | 접근 | 리셋값 | 설명 |
|------|------|------|------|--------|------|
| 0x00 | CTRL | [0] START | W | 0 | 1을 쓰면 작업 시작. 읽으면 항상 0 |
| 0x04 | STATUS | [0] BUSY | RO | 0 | 작업 중이면 1 |
|  |  | [7:4] ERR_CODE | RO | 0 | 마지막 작업의 에러 코드 (§8) |
| 0x08 | IRQ_EN | [0] DONE_EN, [1] ERR_EN | RW | 0 | 인터럽트 허용 |
| 0x0C | IRQ_STATUS | [0] DONE, [1] ERR | W1C | 0 | 이벤트 기록(한 번 1이 되면 유지). 1을 써야 지워짐 |
| 0x10 | DIMS | [6:0] M, [14:8] N, [22:16] K | RW | 0 | 행렬 크기 (유효 범위 1~MAX_DIM) |
| 0x14 | A_BASE | [31:0] | RW | 0 | A[0][0]의 바이트 주소 |
| 0x18 | A_STRIDE | [15:0] | RW | 0 | A의 한 행에서 다음 행까지의 바이트 간격 |
| 0x1C | B_BASE | [31:0] | RW | 0 | B[0][0]의 바이트 주소 |
| 0x20 | B_STRIDE | [15:0] | RW | 0 | B의 행 간격 |
| 0x24 | C_BASE | [31:0] | RW | 0 | C[0][0]의 바이트 주소 |
| 0x28 | C_STRIDE | [15:0] | RW | 0 | C의 행 간격 |
| 0x2C | CYCLES | [31:0] | RO | 0 | 마지막 작업에서 BUSY가 1이었던 클럭 수 |
| 0x30 | VERSION | [31:0] | RO | 0x5341_0002 | 설계 ID와 버전 |
| 0x34 | QCFG | [0] REQ_EN, [1] RELU_EN, [12:8] SHIFT | RW | 0 | 출력단 설정 (§7) |
| 0x38 | QSCALE | [15:0] SCALE | RW | 0 | 재양자화 곱셈 계수, 부호 없음 (§7) |

접근 타입: **RW** 읽기/쓰기, **RO** 읽기 전용, **W** 쓰기 전용, **W1C** 1을 써야 지워짐(Write-1-to-Clear).

추가 규칙:
- CSR 블록은 주소 비트 [7:2]만 봐요. [31:8]과 [1:0]은 무시해요.
- 쓰지 않는 비트는 읽으면 0이고, 써도 무시돼요.
- RO 레지스터에 쓰면 무시되고 응답은 OKAY예요.
- 위 표에 없는 주소에 접근하면 **SLVERR**(에러 응답)을 돌려줘요. 읽으면 데이터 0, 쓰면 아무 효과 없어요.
- CTRL.START는 바이트 0을 쓸 때(`wstrb[0] = 1`)만 동작해요.
- IRQ_STATUS: 하드웨어 이벤트가 비트를 1로 만드는 클럭과 소프트웨어가 그 비트를 지우는 클럭이 겹치면, **비트는 1로 남아요**(이벤트가 이김).
- 설정 레지스터(DIMS, BASE, STRIDE, QCFG, QSCALE)는 **START가 받아들여지는 순간 복사(shadow)**돼요.
  BUSY 중에 바꿔도 되지만 진행 중인 작업에는 영향이 없어요.
- BUSY 중에 START를 쓰면 무시돼요(에러도 아니고, 진행 중인 작업에도 영향 없음).

## 5. 메모리 배치
모든 행렬은 행 우선(row-major), 리틀 엔디안이에요.
- `A[r][c]` (INT8)의 주소 = `A_BASE + r*A_STRIDE + c`
- `B[r][c]` (INT8)의 주소 = `B_BASE + r*B_STRIDE + c`
- `C[r][c]`의 주소 = `C_BASE + r*C_STRIDE + E*c`. 원소 크기 `E`는
  `QCFG.REQ_EN = 0`이면 4바이트(INT32), `QCFG.REQ_EN = 1`이면 1바이트(INT8)예요.
- A_STRIDE가 K보다 작아도 돼요(B_STRIDE와 N도 마찬가지). 그러면 메모리에서 행끼리 겹치는데,
  위 공식 그대로 읽으면 돼요. (C_STRIDE에는 최솟값이 있어요. §8 참고)
- 소프트웨어는 접근하는 모든 주소를 2^32 미만으로 유지해야 해요. 주소가 넘어가서 0으로 돌아가는 경우(wrap-around)의 동작은 정의되지 않아요.

## 6. 동작 순서
1. 소프트웨어가 DIMS, BASE/STRIDE 레지스터, QCFG/QSCALE, IRQ_EN을 설정하고 CTRL.START=1을 써요.
2. 설정값을 검사해요(§8). **설정 에러**면 작업이 즉시 끝나요:
   BUSY는 한 번도 1이 되지 않고, AXI master 트래픽도 없고, ERR_CODE가 설정되고,
   IRQ_STATUS.ERR가 1이 되고, CYCLES는 0이 돼요.
3. 문제가 없으면 BUSY=1이 되고 DUT가:
   1. A의 M개 행을 모두 A 버퍼로 읽고,
   2. B의 K개 행을 모두 B 버퍼로 읽고,
   3. 출력을 ARRAY_N×ARRAY_N 크기의 타일 단위로 계산해요. 타일 순서는 행 우선이에요
      (타일 행 번호가 바깥 루프, 타일 열 번호가 안쪽 루프). 모든 원소를 출력단(§7)에 통과시키고,
      각 타일의 유효한 C 원소를 메모리에 쓴 다음 다음 타일을 계산해요.
4. 마지막 쓰기 응답(B)을 받으면: BUSY=0, ERR_CODE=0, IRQ_STATUS.DONE=1, CYCLES 갱신.
5. IRQ_STATUS.DONE은 **성공한 작업만**, IRQ_STATUS.ERR은 **실패한 작업만** 1로 만들어요. 둘이 동시에 1이 되는 일은 없어요.
   ERR_CODE는 다음 작업이 끝날 때까지 마지막 작업의 코드를 유지해요.

연산: 곱셈 결과는 정확하게(16비트) 계산하고, 누산은 INT32로 해요. MAX_DIM=64에서는 누산기가 overflow 되지 않아요.

### 6.1 DMA 규칙 (AXI4 master)
- `AxSIZE`는 항상 3(beat당 8바이트), `AxBURST`는 항상 INCR(주소가 순서대로 증가)이에요.
- 버스트 하나는 **4KB 경계를 넘지 않고**, 최대 8 beat(`AxLEN` ≤ 7)예요.
- **읽기:**
  - 읽기 버스트는 최대 `MAX_RD_OT`(4)개까지 **outstanding**(요청을 보냈지만 마지막 응답을 아직 못 받은 상태)일 수 있어요.
    진행 중인 버스트는 각자 다른 `ARID`(0~3)를 써요. 한 ID는 그 버스트의 마지막 beat(RLAST)를 받은 뒤에야 다시 쓸 수 있어요.
  - DUT는 서로 다른 ID 사이에서 R beat가 **어떤 순서로 와도** 받아요. 다른 ID의 beat가 한 beat씩 섞여 와도(interleave) 마찬가지예요.
    같은 ID 안에서는 순서대로 와요(AXI4 규칙).
  - 읽기 버스트를 보내는 순서는 정해져 있지 않아요.
  - 각 행은 A의 경우 `[row_addr, row_addr + K)`, B의 경우 `+ N` 범위를 덮는 버스트로 읽어요(8바이트 beat 단위로 올림).
    그래서 마지막 beat 안에서 행 끝 다음의 최대 7바이트까지 더 읽을 수 있지만, 그 이상은 읽지 않아요.
- **쓰기:**
  - 쓰기 버스트는 한 번에 최대 1개만 진행하고, `AWID`는 항상 0이에요.
  - 유효한 C 원소의 바이트만 쓰고, 나머지는 `WSTRB`로 막아요. DUT는 현재 작업의 C 원소 밖에는 절대 쓰지 않아요.
  - 버스트의 `AWVALID`는 첫 `WVALID`보다 먼저 또는 같은 클럭에 올라가요.

## 7. 출력단
모든 누산값 `acc`(부호 있는 32비트)를 메모리에 쓰기 전에 적용해요.

```
REQ_EN = 0 (INT32 출력):
    out = RELU_EN ? max(acc, 0) : acc            // ReLU: 음수면 0

REQ_EN = 1 (INT8 출력):
    p   = acc * SCALE                            // 정확한 곱셈. SCALE은 부호 없는 16비트, p는 49비트 안에 들어감
    r   = (SHIFT == 0) ? p
                       : (p + 2**(SHIFT-1)) >>> SHIFT   // 2^SHIFT로 나누며 반올림
                                                        // (>>>는 산술 시프트 = 내림, 동률이면 +무한대 쪽으로)
    r   = RELU_EN ? max(r, 0) : r
    out = clamp(r, -128, 127)                    // INT8 범위로 자르기(포화)
```
예시 (SCALE=1, SHIFT=1, 즉 2로 나누기): acc=3 → 2 (1.5를 반올림), acc=-3 → -1 (-1.5는 +무한대 쪽으로), acc=-4 → -2.

## 8. 에러 처리
| ERR_CODE | 이름 | 원인 |
|----------|------|------|
| 0 | NONE | 마지막 작업 성공 |
| 1 | BAD_DIM | M, N, K 중 하나가 0이거나 MAX_DIM보다 큼 |
| 2 | BAD_ADDR | A/B/C_BASE나 A/B/C_STRIDE 중 하나가 8의 배수가 아님, 또는 C_STRIDE < E×N (E는 §5) |
| 3 | RD_ERR | 읽기 응답 `RRESP`가 OKAY가 아님 |
| 4 | WR_ERR | 쓰기 응답 `BRESP`가 OKAY가 아님 |

BAD_DIM을 BAD_ADDR보다 먼저 검사해요(둘 다 해당되면 BAD_DIM).

RD_ERR/WR_ERR이 나면 DUT는:
1. 새 버스트를 더 보내지 않고,
2. 이미 보낸 버스트는 끝까지 마무리하고(R beat와 B 응답을 모두 받음),
3. BUSY=0, IRQ_STATUS.ERR=1, CYCLES 갱신으로 작업을 끝내요.

에러가 난 뒤 C의 내용은 정의되지 않아요(어떤 값이든 될 수 있음).

## 9. 리셋
`rst_n`은 비동기 리셋이에요. 리셋이 들어오면 진행 중인 작업을 중단하고 모든 레지스터를 리셋값으로 되돌려요.
리셋 중에는 DUT가 모든 AXI valid 신호를 0으로 내려요.

리셋은 클럭 없이 아무 때나 걸 수 있어요(assert). 대신 `rst_n`은 `clk`의 상승 에지를 최소 두 번 지날 때까지
0으로 유지해야 하고, 풀 때(release)는 리셋 동기화기(reset synchronizer)처럼 `clk`에 맞춰서(상승 에지에서 떨어진 시점에) 풀어요.
DUT와 같은 리셋을 쓰는 모든 블록(예: AXI4 포트 뒤의 메모리)이 리셋을 이렇게 봐요. 이보다 짧은 펄스는 올바른 리셋이 아니에요.

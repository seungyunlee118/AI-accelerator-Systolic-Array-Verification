# SA-GEMM Verification Plan (owner: Seungyun Lee)

> Fill this in from `spec.md`. Every row should trace to a spec section, and say how it is
> stimulated, how it is checked, and how coverage proves it was exercised.
> Two example rows are filled in; replace or extend them.

## 1. Scope
- In scope:
- Out of scope:

## 2. Testbench architecture
(Agents, active/passive, memory model, RAL, scoreboard, reference model, coverage collectors.
Add a block diagram.)

## 3. Feature list
| ID    | Spec § | Feature | Stimulus | Checker | Coverage | Test(s) |
|-------|--------|---------|----------|---------|----------|---------|
| F-01  | 4      | IRQ_STATUS is W1C | RAL write 1/0 patterns to each bit after DONE/ERR events | RAL mirror check + irq pin vs IRQ_STATUS & IRQ_EN | cp_irq_status × cp_write_value | `csr_w1c_test` |
| F-02  | 6.1    | DMA bursts never cross 4 KB | Base addresses placed near 4 KB boundaries | Assertion / memory-model check on every AR/AW | cp_burst_crosses_page_if_unsplit | `dma_4k_test` |
|       |        |         |          |          |          |         |

## 4. Checkers and assertions
| ID | Where (SVA / scoreboard / memory model) | Property |
|----|------------------------------------------|----------|
|    |                                          |          |

## 5. Coverage model
| Covergroup | Coverpoints / bins | Crosses | Goal |
|------------|--------------------|---------|------|
|            |                    |         |      |

## 6. Test list
| Test | Purpose | Sequences | Seeds |
|------|---------|-----------|-------|
|      |         |           |       |

## 7. Sign-off criteria
- Functional coverage:
- Code coverage:
- Regression:
- Open bugs:

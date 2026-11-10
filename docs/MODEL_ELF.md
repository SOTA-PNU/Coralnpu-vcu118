# DDR 모델 ELF 실행 조건

`./coral model <elf>` (`tools/ddr_run.py`) 로 돌릴 수 있는 ELF 의 조건.
받은 IREE 모델 4개(lenet5, charrnn, yolo, vgg)가 모두 이 조건을 만족하고, vector_highmem +
`patches/0013` 비트스트림에서 실행을 확인했다 (11/04, [LOG.md](LOG.md)).
새 ELF 는 이 4개와 같은 툴체인·링커 스크립트·하니스로 빌드했다면 그대로 돌아간다.

## 1. 명령어 셋

4개 모델의 `.riscv.attributes`:

```
rv32i2p1_m2p0_f2p2_zicsr2p0_zifencei2p0_zmmul1p0_zbb1p0_zve32f1p0_zve32x1p0_zvl128b1p0
```

- RV32IMF + Zbb + 벡터 Zve32f, **VLEN 128**
- **압축 명령어(C) 금지.** 코어 misa = `0x40801120` 에 C 가 없다. 일반 툴체인 기본값(`rv32gc`)으로 빌드하면 안 된다
- double(D) 없음
- 매트릭스 유닛(VME) 명령 없음. matrix_* 판은 VU9P 에 들어가지 않아 비트스트림에 없다

## 2. 메모리 배치

| 영역 | 주소 | 크기 | ELF 에서 |
|---|---|---|---|
| ITCM | `0x0000_0000` | 1 MB | **세그먼트 금지.** 로더가 스텁(0x0)과 적재 버퍼(0x1000~)로 쓴다. 있으면 로더가 거부한다 |
| DTCM | `0x0010_0000` | 1 MB | `.data`/`.bss`/스택. `0x1F_F000` 근처는 실행 전까지 로더 메일박스로 쓰인다 (스택 꼭대기라 문제 없음) |
| DDR4 | `0x8000_0000` | 4개 모델은 128 MB 로 링크 | 코드·가중치·힙. 엔트리는 여기(또는 DTCM) |

- ELF 의 LOAD 세그먼트는 DDR 과 DTCM 에만 둔다
- 128 MB 보다 큰 DDR 사용은 검증하지 않았다
- 재배치 정보가 없는 완전 링크 바이너리라 로더가 주소를 옮겨 주지 않는다. 배치가 다르면 다시 링크해야 한다

## 3. 결과 하니스 (심볼)

로더는 실행 종료와 결과를 DTCM 의 심볼로 판단한다. 심볼 테이블이 남아 있어야 한다(strip 금지).

| 심볼 | 용도 |
|---|---|
| `_ret` | **필수.** 로더가 `0x0BADD00D` 를 써 두고, 값이 바뀌면 종료로 본다. 0 = 성공 |
| `inference_status`, `inference_status_code`, `inference_stage` | 상태 |
| `inference_argmax`, `inference_out_count`, `inference_max_value`, `inference_out_sum`, `inference_output` | 출력 |
| `cyc_setup`, `cyc_invoke` | 사이클 수 (32비트: 50 MHz 에서 86 초마다 넘친다. 긴 실행은 벽시계 시간을 볼 것) |
| `status_msg`, `_write` 라인 버퍼 | 텍스트 |

- `_ret` 이 없으면 프로그램이 돌아도 `--timeout`(기본 900 s)까지 기다린 뒤 결과 없이 끝난다
- UART 로 찍는 `printf` 는 로더가 읽지 않는다

## 4. 실행

```bash
./coral model ~/models/<elf>                  # DDR 은 USB-UART 921600 으로 적재 (기본)
./coral model ~/models/<elf> --timeout 7200   # 실행이 15 분을 넘는 모델
./coral model ~/models/<elf> --jtag           # UART 없이 JTAG 로만 (약 57 배 느림)
```

VM 메일박스로는 `vmshare/inbox/NN-name.job` 에 `model <~/models 안의 파일 이름> [--timeout N]`.

## 실측 (11/04, vector_highmem + 0013, 50 MHz)

| 모델 | DDR 적재 | UART 적재 | JTAG 적재 | 실행 | argmax |
|---|---|---|---|---|---|
| lenet5 | 821 KB | 11.2 s | 640 s | 2 s (`cyc_invoke` 560.6 ms) | 7 |
| charrnn | 2062 KB | 27.9 s | 1600 s | 4 s (`cyc_invoke` 3173.6 ms) | 53 |
| yolo | 12333 KB | 166.9 s | 9612 s | 736 s | 959 |
| vgg | 15868 KB | 215.6 s | (약 3.4 h, 외삽) | 94 s (`cyc_invoke` 82.5 s) | 92 |

UART 는 약 73.8 KB/s, JTAG 는 약 1.29 KB/s. UART 와 JTAG 로 적재한 결과는 출력값까지 같다.
argmax 가 정답인지는 기준값(입력 라벨이나 호스트 실행 결과)이 없어 아직 판정하지 않았다.

### 결과 읽기 (11/10, `tools/render_result.py`)

ELF 의 입력(`model_input*_data`, `_shape`)과 보드 출력(`inference_output`, `model_output_elems`로
나눔)을 해석해 그림으로 보였다. 입력 그림과 대조하면 네 모델 중 셋은 답이 맞다.

| 모델 | 입력 | 출력 해석 | 보드 결과 | 입력 그림 |
|---|---|---|---|---|
| lenet5 | 1×1×28×28 f32 | 10 → MNIST 숫자 | **7** (logit 14.27) | 손글씨 7 ✅ |
| vgg | 1×3×32×32 f32 (정규화) | 100 → CIFAR-100 | **tulip** (logit 19.57, 2위 poppy 7.22) | 튤립 ✅ |
| yolo | 1×3×416×416 f32 (레터박스) | 13×13·26×26×255 → YOLOv3-tiny, COCO | **person** 0.96 / 0.84 / 0.50, **bus** 0.54 | 버스 앞 사람 셋 ✅ |
| charrnn | 16 × i64 문자 번호 + h, c (128) | 64 logits + h + c | 다음 문자 #53 (p 0.97) | vocab 표가 없어 판정 불가 |

- yolo 의 argmax 959 는 펼친 출력 텐서의 위치일 뿐 클래스가 아니다. 검출은 앵커 디코딩 + NMS 로 본다.
- YOLO 출력 배치는 NCHW (채널 = 앵커×85 + 필드). 박스가 그림 위 사람·버스와 맞아 확인했다.
- 라벨 표는 ELF 에 없다. 출력 크기로 고르며, 다른 데이터셋으로 학습한 모델이면 라벨이 틀린다.

# CoralNPU on VCU118 — 프로젝트 정리 (2026-11-04)

Google CoralNPU(RISC-V 스칼라 + RVV 벡터 NPU)를 AMD VCU118(xcvu9p-flga2104-2L-e)에 올리고,
받은 IREE 모델 4종을 보드에서 끝까지 추론한 것으로 프로젝트를 마무리한다.
진행 기록은 [LOG.md](LOG.md), 모델 ELF 조건은 [MODEL_ELF.md](MODEL_ELF.md),
반복 측정·효율·다른 구현과의 비교는 [BENCHMARK.md](BENCHMARK.md).

## 1. 결과 요약

| 항목 | 결과 |
|---|---|
| 상류 | google-coral/coralnpu `15573b6`, **무수정** (이 저장소는 패치 0001~0013 + `coral` CLI만 가짐) |
| 구성 | `vector_highmem`: 스칼라 RV32IMF + RVV(VLEN 128), ITCM 1 MB, DTCM 1 MB, DDR4 C1 |
| 클럭 / 타이밍 | 50 MHz, `clk_main` WNS +0.229 ns, 전체 제약 충족 |
| 모델 | lenet5, charrnn, yolo, vgg **4종 모두 보드에서 추론 성공** (`_ret = 0`) |
| 검증 | DDR 적재 체크섬, 보드 UART 출력의 줄별 체크섬, 디버거 값과의 대조, argmax 회귀 |
| 운영 | 보드는 연구실 서버 sota-AIP, GitHub Actions `board-test`로 주 1회 자동 검증 |

## 2. 하드웨어 구성

### 리소스 (vector_highmem, 0013 판)

| 자원 | 사용 | 전체 | 비율 |
|---|---|---|---|
| CLB LUT | 539,046 | 1,182,240 | 45.60 % |
| Block RAM tile | 41.5 | 2,160 | 1.92 % |
| URAM | 192 | 960 | 20.00 % |
| DSP | 395 | 6,840 | 5.77 % |

SLR별 LUT: 52.96 % / 44.45 % / 39.38 %. DDR4 쪽 클럭(`c0_sys_clk_p`, `mmcm_clkout*`)도 타이밍 충족.

### 메모리 맵 (스칼라와 벡터가 같은 주소 공간을 공유)

| 영역 | 주소 | 크기 | 비고 |
|---|---|---|---|
| ITCM | `0x0000_0000` | 1 MB | 명령어. 코어의 **store는 access fault** (읽기만 가능) |
| DTCM | `0x0010_0000` | 1 MB | 데이터, 스택 |
| GPIO / UART1 | `0x4003_0000` / `0x4001_0000` | | UART1은 CP2105(J4)에 연결 |
| DDR4 | `0x8000_0000` | 모델은 128 MB로 링크 | SoC AXI 256 → 512비트 변환 → DDR4-2400 (ui_clk 300 MHz) |

디버거(JTAG)는 ITCM/DTCM만 접근한다. DDR은 코어(스텁)를 거쳐서만 읽고 쓴다.

## 3. 성능

모든 수치는 보드 실측, 50 MHz.

### RVV (VLEN 128, 스칼라 결과와 일치)

| 커널 | 벡터 cycle | 스칼라 cycle | 배수 |
|---|---|---|---|
| vadd.vv u32 m1 | 1,173 | 2,857 | 2.4× |
| vmacc.vv i32 m4 | 422 | 3,377 | 8.0× |
| vredsum i32 m8 | 118 | 1,560 | 13.2× |
| vfmacc.vv f32 m2 | 764 | 5,970 | 7.8× |

### 행렬 곱 (결과 일치)

| 크기 | 벡터 | MAC/cycle | 처리량 | 스칼라 대비 |
|---|---|---|---|---|
| int8 128×128×128 | 1,330,312 cycle | 1.57 | 78.50 MMAC/s | **17.45×** |
| f32 64×64×64 | 250,826 cycle | 1.04 | 52.00 MMAC/s | **17.93×** |

(10/19 vector_normal 판: int8 32³ 1.50 MAC/cycle 17.1×, f32 16³ 0.97 MAC/cycle 17.2×)

### 모델 (연구실 서버, UART 적재, 보드 직접 출력)

| 모델 | DDR 적재 | 추론 | 전체 (적재~출력) | argmax | 출력 |
|---|---|---|---|---|---|
| lenet5 | 821 KB | **560.7 ms** (`cyc_invoke`) | 15.7 s | 7 | 10워드 |
| charrnn | 2,062 KB | **3.17 s** | 34.4 s | 53 | 320워드 |
| yolo | 12,333 KB | **약 736 s** (벽시계) | 918.6 s | 959 | 215,475워드 (862 KB) |
| vgg | 15,868 KB | **82.5 s** | 309.8 s | 92 | 100워드 |

- yolo는 `cyc_invoke`(32비트)가 86초마다 넘쳐서 벽시계 시간만 쓴다.
- 같은 모델을 JTAG/UART, VM/서버에서 각각 돌려도 출력값이 비트 단위로 같았다.

### 데이터 이동

| 경로 | 속도 | vgg(15.5 MB) 적재 |
|---|---|---|
| JTAG (디버그 모듈, progbuf 없음 → 워드마다 abstract command) | 1.29 KB/s | 약 3.4시간 (외삽) |
| **UART 로더** (CP2105, 921600 8N1) | **73.8 KB/s** | 215.6 s |
| 보드 → 호스트 결과 출력 (256바이트마다 ACK) | 약 84 KB/s | yolo 텍스트 1.94 MB를 23 s |

### 빌드

| 판 | 소요 | 비고 |
|---|---|---|
| 0011 | 7시간 47분 | VM RAM 16 GB |
| 0012 | 9시간 10분 | |
| 0013 | 13시간 22분 | VM 메모리 13/15 GB + swap |

합성에 RAM+swap 약 40 GB 필요.

## 4. 어떻게 동작하나

```
[빌드 VM]  ./coral build  →  out/chip_vcu118_vector_highmem.bit (+ 테스트 ELF)
   │ scp
   ▼
[sota-AIP]  ./coral program      Vivado Lab → JTAG → FPGA
            ./coral model <elf>  tools/ddr_run.py
               1. JTAG로 ITCM 0x0에 스텁, 0x400에 출력 루틴, 0x800에 결과 표를 올림
               2. 스텁이 DDR4 보정 완료를 확인 (GPIO bit 0)
               3. DDR 세그먼트를 UART로 전송, 스텁이 DDR에 기록, 체크섬 확인
               4. ELF의 crt0 끝(beqz/ebreak)을 출력 루틴으로 점프하게 패치해 둔 채 엔트리로 점프
               5. 모델 종료 → 출력 루틴이 결과 심볼을 UART로 출력 (줄 끝 =체크섬)
               6. 호스트가 줄 체크섬을 검증하고, 디버거로 읽은 값과 대조
```

- 메일박스는 DTCM `0x1F_F000`. ITCM에 두면 코어 store가 fault 난다 (11/04의 핵심 버그).
- 손으로 쓴 RISC-V 도우미 두 개(`tools/ddr_stub.S`, `tools/result_printer.S`)는 `tools/rvasm.pl`로
  어셈블하고, `perl tools/rvasm.pl --check`가 `ddr_run.py`에 박힌 워드와 일치하는지 검사한다.

## 5. 한계

### 기능
- **정답 판정 없음.** argmax와 출력값은 실행 간 회귀 기준일 뿐, 맞는 답인지는 기준값(입력 라벨,
  호스트 실행 결과)이 없어 판정하지 않았다.
- **매트릭스 유닛(VME/ZVT) 없음.** `matrix_*` 판은 VU9P에 들어가지 않는다 (LUT 87 %, CLB 99 %,
  배선 실패). 상류는 VU13P급을 쓴다.
- **50 MHz 고정.** 클럭을 올리는 시도는 하지 않았다 (WNS +0.229 ns로 여유가 작다).
- ISA 제약: 압축 명령어(C) 없음, double(D) 없음. 일반 `rv32gc` 빌드는 돌지 않는다.
- 모델 ELF는 재배치 정보 없는 완전 링크본이라 메모리 배치가 다르면 다시 링크해야 한다.
  ITCM에 세그먼트가 있으면 안 된다 (MODEL_ELF.md).
- 사이클 카운터 `cyc_*`가 32비트라 86초가 넘는 실행은 넘친다.
- 결과 출력은 crt0 끝 모양(4개 모델 공통)을 찾아 패치하는 방식이라, 다른 crt0로 빌드한 ELF는
  보드 직접 출력이 꺼지고 디버거 읽기만 한다.

### 운영
- **보드는 호스트가 있어야 돈다.** VCU118의 CoralNPU는 네트워크 스택이 없는 베어메탈이라,
  USB(JTAG, UART)가 꽂힌 서버가 적재·실행·결과 수집을 다 한다. 전원이 꺼지면 비트스트림을 다시 올린다.
- **빌드는 라이선스 VM에서만.** Vivado 라이선스가 VM의 MAC에 묶여 있고, 한 판에 9~13시간.
  CI에는 빌드를 넣지 않았다.
- TCM 세그먼트와 제어는 여전히 JTAG(느림). 모델은 TCM 부분이 작아(12 KB) 영향이 작다.
- 공용 서버라 USB 권한이 모든 사용자에게 열려 있다 (`udev/60-vcu118.rules`, MODE 0666).
- VirtualBox USB 패스스루로는 보드→호스트 큰 출력에서 2.8 % 유실이 있었다 (서버 직결은 0).
  원인을 측정으로 분리하지는 않았다.

### 확인하지 못한 것
- 0013(DDR4 입력 클럭 수정)이 실제로 필요했는지: 0011·0012 판의 DDR4 상태는 로더 버그 때문에
  측정된 적이 없다. 0013 없이 만든 IP의 VCO 4250 MHz 계산은 유효하다.

## 6. 운영 방법

### 위치
| 무엇 | 어디 |
|---|---|
| 보드 | 연구실 서버 **sota-AIP** (192.168.1.150, 외부 `sota.pusan.ac.kr:25622`), USB J106(JTAG) + J4(UART) |
| 저장소 (서버) | `~/Coralnpu-vcu118` (계정 `ehdgns`) |
| 비트스트림·설정·테스트 ELF | `~/Coralnpu-vcu118/out/` (`SHA256SUMS`로 검증) |
| 모델 ELF | `~/models/` (`SHA256SUMS`) |
| 보드 출력 결과 | `~/Coralnpu-vcu118/out/results/<모델>-<시각>.uart.txt` |
| Vivado Lab | `/tools/Xilinx/2026.1/Vivado_Lab` |
| CI 러너 | `~/actions-runner-vcu118` (서비스 `actions.runner.SOTA-PNU-Coralnpu-vcu118.sota-aip-vcu118`) |

### 자주 쓰는 명령 (서버)
```bash
cd ~/Coralnpu-vcu118
CONFIG=vector_highmem ./coral program              # 비트스트림 (전원을 껐다 켠 뒤)
./coral run out/vcu118_rvv_test_highmem.elf        # RVV 회귀
./coral run out/vcu118_matmul_bench_highmem.elf    # 행렬 곱
./coral model ~/models/lenet5                      # 모델 (UART 적재 + 보드 직접 출력)
./coral model ~/models/yolo --timeout 2400         # 15분 넘게 도는 모델
./coral model ~/models/lenet5 --jtag               # UART 없이 (느림)
./coral model ~/models/lenet5 --no-print           # 보드 직접 출력 끄기
```

### CI
- GitHub `SOTA-PNU/Coralnpu-vcu118` → Actions → **board-test** → Run workflow
  (모델 선택 가능, 기본 lenet5 charrnn vgg). 매주 월 04:00 KST에 4종 전부 자동 실행.
- 통과 조건: `_ret = 0`, 보드 출력 줄 체크섬 전부 일치, 디버거 대조 일치, argmax가 7/53/959/92.
- 로그는 실행 페이지의 artifact `vcu118-board-test` (30일).
- PR로는 실행되지 않는다 (포크 코드가 연구실 서버에서 돌지 않게).

## 7. GitHub에 올리는 법

### 규칙
1. **이미 적용된 `patches/*.patch`는 절대 고치지 않는다.** `coral`이 "changed since it was applied"로
   **모든 빌드를 중단**한다 (11/01에 실제로 겪음). RTL·빌드 변경은 **새 번호 패치**로.
2. 저장소 루트의 `tools/`, `vivado/*.tcl`, `coral`, 문서는 바로 고쳐서 커밋한다 (다음 실행에 즉시 반영).
3. `tools/ddr_stub.S`나 `tools/result_printer.S`를 고치면 `perl tools/rvasm.pl`로 다시 어셈블해
   `ddr_run.py`의 워드 목록을 바꾸고, `perl tools/rvasm.pl --check`가 ok인지 확인한다.
4. 커밋 메시지는 무엇을 왜 바꿨는지와 측정 근거를 적는다 (기존 커밋 참고).

### 일반 변경 (스크립트, 문서)
```bash
git clone https://github.com/SOTA-PNU/Coralnpu-vcu118.git && cd Coralnpu-vcu118
# ... 수정 ...
perl tools/rvasm.pl --check            # 도우미를 건드렸다면
python3 -m py_compile tools/ddr_run.py # 로더를 건드렸다면
git add -A
git commit -m "tools/ddr_run: 무엇을 왜"
git push origin main
```
- Windows에서는 Git for Windows의 자격 증명 관리자가 처음 push 때 GitHub 로그인을 묻는다.
- 서버에서 push하려면 서버 계정에 GitHub 인증(SSH 키 또는 토큰)을 따로 등록해야 한다.
  지금은 서버가 GitHub에서 `git pull`만 한다.

### RTL·빌드 변경 (새 패치)
```bash
./coral setup                          # work/coralnpu 에 상류 + 기존 패치 적용
cd work/coralnpu
# ... 수정 ...
git add -A && git commit -m "fpga/vcu118: 설명"
git format-patch -1 -o ../../patches --start-number 14   # 다음 번호 (현재 0013까지)
cd ../..
git add patches/0014-*.patch && git commit -m "patches/0014: 설명" && git push origin main
```
그 다음 빌드 VM에서 `./coral build` (9~13시간) → 비트스트림을 서버 `out/`으로 복사하고
`SHA256SUMS`를 갱신 → `./coral program` → CI 실행.

### 서버와 VM에 반영
- **서버:** `cd ~/Coralnpu-vcu118 && git pull --ff-only origin main`
- **빌드 VM:** 인터넷이 되면 `git pull`. 메일박스 방식에서는 Windows에서
  `git bundle create vmshare/bundles/<이름>.bundle main ^<VM의 HEAD>` 후 `update` job.

## 8. 파일 안내

| 파일 | 내용 |
|---|---|
| `coral` | 모든 작업의 입구 (setup, build, program, run, model, console …) |
| `patches/0001~0013` | 상류 위에 얹는 VCU118 포팅·DDR4·진단 패치 |
| `tools/ddr_run.py` | DDR 모델 로더 (UART/JTAG 적재, crt0 패치, 결과 수집·검증) |
| `tools/ddr_stub.S` | ITCM 적재 스텁 (DDR 보정 대기, 복사, 체크섬, UART 수신, 점프) |
| `tools/result_printer.S` | 보드가 결과를 UART로 직접 출력하는 루틴 |
| `tools/rvasm.pl` | 위 두 도우미용 소형 RV32I 어셈블러와 검사기 |
| `tools/setup-board-host.sh` | 보드 서버 준비 (Vivado Lab, 드라이버, udev, 로캘) |
| `tools/vm-agent.sh`, `tools/overnight.sh` | 빌드 VM 메일박스 에이전트, 야간 빌드·회귀 |
| `.github/workflows/board-test.yml` | 보드 CI |
| `docs/LOG.md` | 날짜별 진행 기록과 측정값 |
| `docs/MODEL_ELF.md` | 모델 ELF 실행 조건 |

## 9. 타임라인

| 날짜 | 내용 |
|---|---|
| 10/07~10/14 | 상류 고정, 포팅 패치, VM 빌드 환경 |
| 10/16~10/19 | 첫 보드 bring-up, RVV·행렬 곱 확인 (vector_normal) |
| 10/21~10/23 | 매트릭스 판 배선 실패 → vector_highmem |
| 10/26~10/30 | DDR4 C1 연결(0009), 보정 펌웨어(0010), 진단 판(0011), VM 메일박스 |
| 11/02~11/03 | 파워온 리셋(0012), DDR4 입력 클럭 원인 확정(0013) |
| 11/04 | 로더 ITCM 메일박스 버그 → DDR4 동작, 모델 4종 실행, UART 로더(57배), 보드 직접 출력, 서버 이전, CI |

## 10. 남은 과제

- 모델 출력 정답 판정 (입력 라벨 또는 호스트 기준 결과)
- 매트릭스 판: VU13P급 보드에서 (`vcu118_vme_test`는 준비됨)
- 64비트 사이클 측정 (`mcycleh`)으로 긴 실행 시간 정확히
- 0013 없는 판을 고친 로더로 다시 돌려 0013의 필요성 확정
- 클럭 상향, 행렬 곱 커널 최적화(레지스터 블로킹), 레이어 단위 측정
- 상류 결함 보고: autoboot 리셋 net 선언 순서
- 빌드 VM을 새 PC로 이전 (RAM 64 GB면 빌드 시간 단축 예상)

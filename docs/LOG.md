# 작업 로그

CoralNPU (상류 `google-coral/coralnpu` @ 15573b69) 를 AMD VCU118 (xcvu9p-flga2104-2L-e) 에 올린 기록.

## [10/7] 환경 준비 — 상류 고정, 포팅 패치, 원클릭 도구

- 상류 fpga/ SoC 를 VCU118 로 옮기는 패치 작성: 125 MHz 클럭, 핀, BSCANE2 디버그 경로, 부팅 ROM (`patches/0001`)
- 저장소 구성: 상류 고정 커밋 + `patches/` + `coral` CLI
  (`setup` / `build` / `program` / `up` / `run` / `resume` / `sw`)

## [10/13] 빌드 환경 — VirtualBox VM + 전용 라이선스

- 공용 서버 사용 불가. Windows PC 에 Ubuntu 22.04 VM 을 만들고, MAC 을 고정해 라이선스 Host ID 로 사용
- VCU118 Device-Locked 라이선스 발급. Vivado 2026.1 설치 후 xcvu9p 합성 확인
- 보드 USB(JTAG, UART)를 VM 으로 패스스루. JTAG tap 0x14b31093 인식

## [10/14] 첫 빌드와 환경 문제

- 빌드 선행 조건 수정
  - clang 미설치
  - Bazel 이 가짜 HOME 을 써서 라이선스를 찾지 못함 → `XILINXD_LICENSE_FILE` 로 전달
- 합성 중 메모리 부족으로 강제 종료 (RAM 20 GB + 스왑 2 GB) → 스왑 추가
- 매트릭스 판(VME) VCU118 타깃 추가, 50 MHz (`patches/0002`)

## [10/16] 첫 보드 bring-up, 상류 버그 발견

- vector_normal 비트스트림
  - LUT 533k (45%)
  - 50 MHz 셋업 충족, WNS +0.26 ns
  - 홀드 위반 6곳은 모두 ISP 의 비동기 리셋 경로
- 배선 도중 VM 이 꺼짐 → 배치 체크포인트에서 배선만 다시 돌려 복구. 이 절차를 `coral resume` 으로 자동화
- 보드 증상: 클럭과 JTAG 은 정상인데 코어가 시작하지 않음
  - LED 7:4 가 움직이지 않음
  - dmstatus 는 running 인데 halt 되지 않음
- **원인 (상류 버그):** `fpga/rtl/coralnpu_soc.sv` 가 `gen_autoboot` 안에서 `rst_main_nqq` 를 선언보다 먼저 사용함
  - 이 참조가 암시적인 미구동 net 이 됨 (Synth 8-3848)
  - Vivado 가 autoboot FSM 을 지움 → CSR resetReg(INIT=1) 를 아무도 풀지 않아 코어가 영원히 리셋 상태
  - netlist 검사(autoboot 셀 0개)와 iverilog 재현으로 확정
  - `patches/0004`: 선언 위치를 위로 옮기고, 합성 직후 autoboot 존재를 확인하는 검사를 추가
- OpenOCD 0.11 호환 (`patches/0003`)
- BSCANE2 경로 실측: IR 18, USER3 0x22924, USER4 0x23924, DR 패딩 문제 없음

## [10/19] CoralNPU 동작 확인

- `./coral up`: ROM 배너 → JTAG 적재 → hello.elf → `DONE`
- RVV 검증 (`vcu118_rvv_test`, `patches/0005`): vadd / vmacc / vredsum / vfmacc 결과가 모두 스칼라와 일치
  - VLEN 128 비트를 하드웨어에서 직접 확인

  | 커널 (N=259, e32) | 벡터 사이클 | 스칼라 사이클 | 배율 |
  |---|---|---|---|
  | vadd.vv u32 m1 | 1,173 | 2,857 | 2.4× |
  | vmacc.vv i32 m4 | 422 | 3,377 | 8.0× |
  | vredsum i32 m8 | 118 | 1,560 | 13.2× |
  | vfmacc.vv f32 m2 | 764 | 5,970 | 7.8× |

- 행렬곱 벤치마크 (`vcu118_matmul_bench`, `patches/0006`, 50 MHz, 결과 일치)

  | 행렬곱 | MAC/cycle | 처리량 | 스칼라 대비 |
  |---|---|---|---|
  | int8×int8→int32, 32×32×32 | 1.50 | 75.5 MMAC/s | 17.1× |
  | f32, 16×16×16 | 0.97 | 48.9 MMAC/s | 17.2× |

- 연속 실행 수정
  - 증상: 프로그램이 끝나면 `mpause` 의 halted 플래그가 남아 다음 프로그램이 실행되지 않음
  - 수정: `coral load` 가 적재 전에 `reset halt` 를 수행
  - 확인: 비트스트림을 다시 올리지 않고 3회 연속 실행
- 콘솔은 CP2105 의 **if01**. ttyUSB 번호는 부팅마다 바뀌므로 by-id 이름으로 찾음

## [확인] 빌드 환경 제약

- 호스트 27 GB 에 VM 20 GB 를 주면 Windows 메모리가 98% 까지 차서 VM 이 멈추거나 꺼짐 → VM 은 16 GB 로 두고 부족분은 VM 안 스왑으로 처리
- Ubuntu 의 systemd-oomd 가 스왑을 쓰는 Vivado 를 강제 종료 → 비활성화 (`tools/setup-host.sh`)
- vector 빌드 소요 시간: 7시간에서 2.5일까지 (메모리 압박에 좌우)
- JTAG 적재 속도는 약 1.5–1.9 KiB/s

## [10/21] matrix_normal 은 VU9P 에 들어가지 않음 (배선 실패)

- 합성 → 배치 → physopt 까지는 완료. 배선(`coral resume`)에서 실패
  - `Route 35-162`: 142,180 개 신호가 혼잡 때문에 배선되지 못함
  - `Route 35-2`: node overlap 330,804 개가 남음
  - overlap 이 1,875,633 에서 시작. vector_normal 은 263,215 에서 시작해 0 까지 내려갔음
- 배치 후 사용률 (`chip_vcu118_physopt.dcp`)

  | 자원 | vector_normal | matrix_normal (ISP 제거) |
  |---|---|---|
  | CLB LUT | 533k (45%) | **1,030k (87%)** |
  | CLB (슬라이스) | — | **99.3%** |
  | 레지스터 | 226k (10%) | 251k (11%) |
  | URAM / DSP | — | 14% / 12% |
  | SLR1→SLR2 교차 | — | 8,854 (51%) |

- 결론
  - 매트릭스 유닛이 LUT 를 약 50만 개 더 씀. VU9P(118만 LUT)에서는 CLB 가 99% 차서 배선 자원이 남지 않음
  - 상류는 매트릭스 판을 VU13P(173만 LUT, 약 60%)에서 쓴다
  - 클럭을 낮춰도 해결되지 않음 (타이밍이 아니라 배선 자원 문제)
  - **VCU118 의 구성은 vector_normal / vector_highmem 으로 확정.** 매트릭스 판은 더 큰 FPGA 가 필요함
- 빌드 환경 메모: 학교 PC 의 VBS / 메모리 무결성 때문에 VirtualBox 가 NEM 모드(AMD-V 미사용)로 동작함
  - 그래서 soft lockup 이 생기고 빌드 시간이 크게 늘어남
  - 보안 설정은 기관 관리 대상이라 원상 복구함

## [10/21] highmem 판으로 진행

- vector_highmem 을 사용함: ITCM / DTCM 각 1 MB, 상류 구성 그대로
- 테스트 프로그램의 highmem 링크판 추가 (`patches/0008`)
  - `*_highmem.elf`
  - matmul 은 int8 128³, f32 64³
- `coral up` / `coral sw` 는 CONFIG 가 *highmem 이면 `_highmem` ELF 를 사용
- `tools/overnight.sh <config>`: 빌드 → 보드 적재 → rvv / matmul

## [10/23] vector_highmem 보드 결과

- 빌드 10/22 16:51 → 10/23 03:41 (약 11시간)
- 타이밍: 라우팅 직후 WNS −0.972 ns → post-route phys_opt 후 **통과** (clk_main 50 MHz WNS 0.000, 실패 0)
- 자원: LUT 43.7%, URAM 192 (20%), BRAM 0, DSP 392
- RVV PASS
- matmul int8 128³ 78.5 MMAC/s (스칼라 대비 17.45배), f32 64³ 52.0 MMAC/s (17.93배)

## [10/26] 모델 ELF 실행 준비: DDR4 + JTAG 로더

- 대상: IREE 모델 ELF (lenet5, charrnn, vgg, yolo)
  - 코드와 가중치가 DDR 0x8000_0000 에 있음 (0.8 ~ 16 MB)
  - 결과는 DTCM 의 `_ret`, `inference_*`, `status_msg`
- 상류(Nexus) 방식
  - DDR4 MIG + `nexus_loader` (FTDI SPI → SoC SPI 디바이스)
  - MIG 코어는 Google 내부 경로에만 있음
- VCU118 에서의 결정 (클럭 50 MHz 유지)
  - DDR4: Vivado IP 카탈로그로 C1 컨트롤러 생성 (보드 파일 사용, AXI 256 비트, ECC 없음)
  - 로더: 보드에 SPI 로 쓸 FTDI 가 없어 JTAG 사용. 디버그 모듈은 TCM 만 접근 가능
    - ITCM 의 작은 스텁(`tools/ddr_stub.S`)이 DDR 로 복사
    - 체크섬으로 검증 후 엔트리로 점프
- 추가한 것
  - `./coral ddr4-probe`: 합성 없이 IP 만 만들어 설정·포트 목록 확인 (몇 분)
  - `./coral model <elf>`: 적재 → 실행 → 결과 출력
- 다음: probe 결과로 `patches/0009` (chip_vcu118 에 DDR4 연결) 작성 → highmem 재빌드

## [10/29] DDR4 C1 연결 (`patches/0009`)

- `./coral ddr4-probe synth` 결과 (Vivado 2026.1, 보드 파일 vcu118 3.0)
  - 인터페이스 `ddr4_sdram_c1_062`, MT40A256M16LY-062E, 64비트, DDR4-2400
  - 보드 프리셋이 폭·속도를 고정함: AXI 512비트, ui_clk 300 MHz (32비트/DDR4-2000 설정은 무시됨)
  - 컨트롤러만 합성: 포트 118개 전부 배치됨 (sys_clk E12, dq[0] F11), LUT 약 2만
- 연결 방식
  - SoC DDR AXI(256비트, 50 MHz) → `axi_dwidth_converter`(256→512, 비동기 클럭 변환) → DDR4 컨트롤러(300 MHz)
  - 상류 Nexus 는 SoC DDR 쪽을 ui_clk 로 돌리지만, 여기서는 300 MHz 를 Xilinx IP 안에만 둠
  - 주소 0x8000_0000 → 컨트롤러 0 (비트 31 제거)
  - DDR 제어 포트(Nexus 의 ECC 레지스터)는 OKAY 응답기
  - 보정 완료 신호 → GPIO 입력 비트 0, LED 7 (LED 6:4 = GPIO 2:0)
- 검사
  - Verilator 로 top 포트 연결 검사 (IP 는 생성된 템플릿으로 만든 stub)
  - 패치 0001~0009 가 상류 15573b6 에 깨끗이 적용되는 것 확인
  - IP 설정이 RTL 과 다르면 setup 훅에서 바로 중단

## [10/29] 보드를 학교 Linux 서버 PC 로 옮기기

- 빌드(라이선스)는 이 PC 의 VM 에 그대로 두고, 서버 PC 는 보드 연결·적재·실행만 맡음
  - ZCU102 는 ARM + 리눅스가 SD 로 스스로 부팅했지만, VCU118 은 USB 로 연결된 호스트가 항상 필요함
- `tools/setup-board-host.sh`: 실행 전용 설치 (openocd, udev, Vivado Lab Edition, 케이블 드라이버, 파일 확인)
- `coral program`: 라이선스가 필요 없는 `vivado_lab` 으로도 동작
- 모델 ELF 는 VM `~/models` 에 복사됨 (Windows → VM: `scp -P 2222`, NAT 포트 전달 127.0.0.1:2222)

## [진행 예정]

- (보류) 매트릭스 판: VU13P 급 보드에서. `vcu118_vme_test` 는 준비돼 있음
- 빌드 전용 PC 확보 (메모리 64 GB 이상, VBS 없음)
- 보드에 올린 ELF 에 벡터 명령이 실제로 들어 있는지 objdump 로 확인
- 행렬곱 커널 최적화 (레지스터 블로킹), 신경망 레이어 단위 측정
- JTAG 적재 속도 개선
- DDR4 MIG 연결 (patches/0009, 10/26 진행 중)
- 상류 결함 보고: autoboot 리셋 net 선언 순서 (Nexus ROM 빌드도 같은 문제로 추정)

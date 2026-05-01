pragma circom 2.1.9;

include "lib_uav_safety.circom";
include "../node_modules/circomlib/circuits/poseidon.circom";

// ─────────────────────────────────────────────────────────────────────────────
// Distance30mTimeDetectionCommitment
//
// プライバシー保護型 UAV 安全検証回路。
//
// 座標はすべて private input のまま回路に渡し、Poseidon ハッシュ（commitment）
// だけを public output として公開する。これにより、検証者は「どこにいたか」を
// 知ることなく「30m 以内に接近したか否か」を確認できる。
//
// Public outputs の意味:
//   drone_commitment   = Poseidon4(drone_lat, drone_lon, drone_alt, drone_time)
//   target_commitment  = Poseidon4(target_lat, target_lon, target_alt, target_time)
//   frame_binding      = Poseidon2(frame_commitment_hi, frame_commitment_lo)
//                        動画フレーム証拠を proof にバインドする値
//   within30           = distance_ok AND time_ok
//   within30_and_detected = within30 AND detection_bundle_ok
// ─────────────────────────────────────────────────────────────────────────────
template Distance30mTimeDetectionCommitment(
    LAT_CM_NUM,
    LON_CM_NUM,
    GEO_DEN,
    DISTANCE_LIMIT_CM,
    TIME_LIMIT_SEC,
    DETECTION_MIN_SCORE_BPS,
    UAV_CLASS_ID
) {
    // ── Private inputs: ドローン側ログ ──────────────────────────────────────
    signal input drone_lat_e7_norm;
    signal input drone_lon_e7_norm;
    signal input drone_alt_cm;
    signal input drone_time_sec;

    // ── Private inputs: 利用者側ログ ────────────────────────────────────────
    signal input target_lat_e7_norm;
    signal input target_lon_e7_norm;
    signal input target_alt_cm;
    signal input target_time_sec;

    // ── Private inputs: 動画検知ログ ────────────────────────────────────────
    signal input uav_detected;
    signal input detection_score_bps;
    signal input detection_class_id;
    signal input frame_time_sec;
    // 動画フレームの外部ハッシュ（Poseidon や SHA などで事前計算した 254-bit 値を
    // hi / lo の 2 つの 127-bit 整数に分割して渡す）
    signal input frame_commitment_hi;
    signal input frame_commitment_lo;

    // ── Public outputs: 距離・時刻判定 ──────────────────────────────────────
    signal output within30;
    signal output distance_ok;
    signal output time_ok;

    // ── Public outputs: 検知判定 ─────────────────────────────────────────────
    signal output detection_ok;
    signal output frame_time_ok;
    signal output detection_bundle_ok;
    signal output within30_and_detected;

    // ── Public outputs: Poseidon コミットメント ──────────────────────────────
    // 座標の実値は開示せず、ハッシュ値だけを公開する
    signal output drone_commitment;
    signal output target_commitment;
    // 動画フレーム証拠を proof に暗号学的にバインドする値
    signal output frame_binding;

    // ── 内部 signal ──────────────────────────────────────────────────────────
    signal detection_gate;
    signal detection_time_gate;

    // ── 距離・時刻コア判定 ───────────────────────────────────────────────────
    component base = Distance30mTimeCore(
        LAT_CM_NUM,
        LON_CM_NUM,
        GEO_DEN,
        DISTANCE_LIMIT_CM,
        TIME_LIMIT_SEC
    );

    base.drone_lat_e7_norm  <== drone_lat_e7_norm;
    base.drone_lon_e7_norm  <== drone_lon_e7_norm;
    base.drone_alt_cm       <== drone_alt_cm;
    base.drone_time_sec     <== drone_time_sec;
    base.target_lat_e7_norm <== target_lat_e7_norm;
    base.target_lon_e7_norm <== target_lon_e7_norm;
    base.target_alt_cm      <== target_alt_cm;
    base.target_time_sec    <== target_time_sec;

    within30    <== base.within30;
    distance_ok <== base.distance_ok;
    time_ok     <== base.time_ok;

    // ── 検知スコア・クラス検証 ───────────────────────────────────────────────
    uav_detected * (uav_detected - 1) === 0;

    component scoreMinLeq = LessEqThan(16);
    scoreMinLeq.in[0] <== DETECTION_MIN_SCORE_BPS;
    scoreMinLeq.in[1] <== detection_score_bps;

    component classEq = IsEqual(8);
    classEq.in[0] <== detection_class_id;
    classEq.in[1] <== UAV_CLASS_ID;

    detection_gate <== uav_detected * scoreMinLeq.out;
    detection_ok   <== detection_gate * classEq.out;

    // ── フレーム時刻検証 ─────────────────────────────────────────────────────
    component frameTimeDiff = AbsDiff(64);
    frameTimeDiff.a <== frame_time_sec;
    frameTimeDiff.b <== target_time_sec;

    component frameTimeLeq = LessEqThan(64);
    frameTimeLeq.in[0] <== frameTimeDiff.out;
    frameTimeLeq.in[1] <== TIME_LIMIT_SEC;

    frame_time_ok <== frameTimeLeq.out;

    // ── 検知バンドル判定 ─────────────────────────────────────────────────────
    detection_time_gate  <== detection_ok * frame_time_ok;
    detection_bundle_ok  <== detection_time_gate;
    within30_and_detected <== within30 * detection_bundle_ok;

    // ── Poseidon コミットメント計算 ──────────────────────────────────────────
    // ドローン座標コミットメント: Poseidon(lat, lon, alt, time)
    component droneHash = Poseidon(4);
    droneHash.inputs[0] <== drone_lat_e7_norm;
    droneHash.inputs[1] <== drone_lon_e7_norm;
    droneHash.inputs[2] <== drone_alt_cm;
    droneHash.inputs[3] <== drone_time_sec;
    drone_commitment <== droneHash.out;

    // 利用者座標コミットメント: Poseidon(lat, lon, alt, time)
    component targetHash = Poseidon(4);
    targetHash.inputs[0] <== target_lat_e7_norm;
    targetHash.inputs[1] <== target_lon_e7_norm;
    targetHash.inputs[2] <== target_alt_cm;
    targetHash.inputs[3] <== target_time_sec;
    target_commitment <== targetHash.out;

    // フレームバインド: Poseidon(frame_commitment_hi, frame_commitment_lo)
    // 外部ハッシュを回路内で再ハッシュして proof に結びつける
    component frameHash = Poseidon(2);
    frameHash.inputs[0] <== frame_commitment_hi;
    frameHash.inputs[1] <== frame_commitment_lo;
    frame_binding <== frameHash.out;
}

component main = Distance30mTimeDetectionCommitment(
    11132000,   // LAT_CM_NUM:  緯度 1度 ≈ 111.32 km → cm
    9128800,    // LON_CM_NUM:  経度 1度 ≈ 91.288 km → cm（北緯 35° 近辺）
    10000000,   // GEO_DEN:     E7 スケールの分母
    3000,       // DISTANCE_LIMIT_CM: 30 m
    5,          // TIME_LIMIT_SEC:     5 秒
    7000,       // DETECTION_MIN_SCORE_BPS: 70.00% (basis points)
    1           // UAV_CLASS_ID
);

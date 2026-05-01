pragma circom 2.1.9;

include "lib_uav_safety.circom";

// ─────────────────────────────────────────────────────────────────────────────
// Distance30mTimeSeries
//
// N ペアの時系列観測データを受け取り、いずれか 1 つでも「30m 以内かつ TIME_LIMIT_SEC
// 以内」に該当するかを証明する。
//
// 全座標は private input。public output は:
//   within30[N]   = 各ペアの判定フラグ（0 or 1）
//   any_within30  = OR 削減後の最終判定（1 つでも近接すれば 1）
// ─────────────────────────────────────────────────────────────────────────────
template Distance30mTimeSeries(
    N,
    LAT_CM_NUM,
    LON_CM_NUM,
    GEO_DEN,
    DISTANCE_LIMIT_CM,
    TIME_LIMIT_SEC
) {
    // ── Private inputs: N 個のドローン観測 ──────────────────────────────────
    signal input drone_lat_e7_norm[N];
    signal input drone_lon_e7_norm[N];
    signal input drone_alt_cm[N];
    signal input drone_time_sec[N];

    // ── Private inputs: N 個の利用者観測 ────────────────────────────────────
    signal input target_lat_e7_norm[N];
    signal input target_lon_e7_norm[N];
    signal input target_alt_cm[N];
    signal input target_time_sec[N];

    // ── Public outputs ───────────────────────────────────────────────────────
    signal output within30[N];
    signal output any_within30;

    // ── N 個の Distance30mTimeCore インスタンス ──────────────────────────────
    component core[N];

    for (var i = 0; i < N; i++) {
        core[i] = Distance30mTimeCore(
            LAT_CM_NUM,
            LON_CM_NUM,
            GEO_DEN,
            DISTANCE_LIMIT_CM,
            TIME_LIMIT_SEC
        );
        core[i].drone_lat_e7_norm  <== drone_lat_e7_norm[i];
        core[i].drone_lon_e7_norm  <== drone_lon_e7_norm[i];
        core[i].drone_alt_cm       <== drone_alt_cm[i];
        core[i].drone_time_sec     <== drone_time_sec[i];
        core[i].target_lat_e7_norm <== target_lat_e7_norm[i];
        core[i].target_lon_e7_norm <== target_lon_e7_norm[i];
        core[i].target_alt_cm      <== target_alt_cm[i];
        core[i].target_time_sec    <== target_time_sec[i];
        within30[i] <== core[i].within30;
    }

    // ── OR 削減: any_within30 = within30[0] OR within30[1] OR ... ───────────
    // a OR b = a + b - a*b
    signal or_chain[N];
    signal or_ab[N];

    or_chain[0] <== within30[0];
    or_ab[0] <== 0;  // インデックス 0 は未使用のため 0 に固定

    for (var i = 1; i < N; i++) {
        or_ab[i] <== or_chain[i-1] * within30[i];
        or_chain[i] <== or_chain[i-1] + within30[i] - or_ab[i];
    }

    any_within30 <== or_chain[N-1];
}

component main = Distance30mTimeSeries(
    20,         // N: 20 ペアの時系列観測
    11132000,   // LAT_CM_NUM:  緯度 1度 ≈ 111.32 km → cm
    9128800,    // LON_CM_NUM:  経度 1度 ≈ 91.288 km → cm（北緯 35° 近辺）
    10000000,   // GEO_DEN:     E7 スケールの分母
    3000,       // DISTANCE_LIMIT_CM: 30 m
    5           // TIME_LIMIT_SEC:     5 秒
);

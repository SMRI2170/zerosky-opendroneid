pragma circom 2.1.9;

include "lib_uav_safety.circom";

template Distance30mTimeDetectionFlag(
    LAT_CM_NUM,
    LON_CM_NUM,
    GEO_DEN,
    DISTANCE_LIMIT_CM,
    TIME_LIMIT_SEC,
    DETECTION_MIN_SCORE_BPS,
    UAV_CLASS_ID
) {
    signal input drone_lat_e7_norm;
    signal input drone_lon_e7_norm;
    signal input drone_alt_cm;
    signal input drone_time_sec;

    signal input target_lat_e7_norm;
    signal input target_lon_e7_norm;
    signal input target_alt_cm;
    signal input target_time_sec;

    signal input uav_detected;
    signal input detection_score_bps;
    signal input detection_class_id;

    signal output within30;
    signal output distance_ok;
    signal output time_ok;
    signal output score_ok;
    signal output class_ok;
    signal output detection_ok;
    signal output within30_and_detected;
    signal detection_gate;

    component base = Distance30mTimeCore(
        LAT_CM_NUM,
        LON_CM_NUM,
        GEO_DEN,
        DISTANCE_LIMIT_CM,
        TIME_LIMIT_SEC
    );

    base.drone_lat_e7_norm <== drone_lat_e7_norm;
    base.drone_lon_e7_norm <== drone_lon_e7_norm;
    base.drone_alt_cm <== drone_alt_cm;
    base.drone_time_sec <== drone_time_sec;
    base.target_lat_e7_norm <== target_lat_e7_norm;
    base.target_lon_e7_norm <== target_lon_e7_norm;
    base.target_alt_cm <== target_alt_cm;
    base.target_time_sec <== target_time_sec;

    uav_detected * (uav_detected - 1) === 0;

    component scoreMinLeq = LessEqThan(16);
    scoreMinLeq.in[0] <== DETECTION_MIN_SCORE_BPS;
    scoreMinLeq.in[1] <== detection_score_bps;

    component classEq = IsEqual(8);
    classEq.in[0] <== detection_class_id;
    classEq.in[1] <== UAV_CLASS_ID;

    within30 <== base.within30;
    distance_ok <== base.distance_ok;
    time_ok <== base.time_ok;
    score_ok <== scoreMinLeq.out;
    class_ok <== classEq.out;
    detection_gate <== uav_detected * score_ok;
    detection_ok <== detection_gate * class_ok;
    within30_and_detected <== within30 * detection_ok;
}

component main = Distance30mTimeDetectionFlag(
    11132000,
    9128800,
    10000000,
    3000,
    5,
    7000,
    1
);

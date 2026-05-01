pragma circom 2.1.9;

include "lib_uav_safety.circom";

template Distance30mTimeFeatureClassifier(
    LAT_CM_NUM,
    LON_CM_NUM,
    GEO_DEN,
    DISTANCE_LIMIT_CM,
    TIME_LIMIT_SEC,
    FEATURE0_WEIGHT,
    FEATURE1_WEIGHT,
    FEATURE2_WEIGHT,
    FEATURE3_WEIGHT,
    FEATURE_SCORE_THRESHOLD
) {
    signal input drone_lat_e7_norm;
    signal input drone_lon_e7_norm;
    signal input drone_alt_cm;
    signal input drone_time_sec;

    signal input target_lat_e7_norm;
    signal input target_lon_e7_norm;
    signal input target_alt_cm;
    signal input target_time_sec;

    signal input frame_time_sec;
    signal input features[4];

    signal output within30;
    signal output distance_ok;
    signal output time_ok;
    signal output frame_time_ok;
    signal output feature_score;
    signal output model_ok;
    signal output within30_and_model;

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

    component frameTimeDiff = AbsDiff(64);
    frameTimeDiff.a <== frame_time_sec;
    frameTimeDiff.b <== target_time_sec;

    component frameTimeLeq = LessEqThan(64);
    frameTimeLeq.in[0] <== frameTimeDiff.out;
    frameTimeLeq.in[1] <== TIME_LIMIT_SEC;

    feature_score <==
        features[0] * FEATURE0_WEIGHT +
        features[1] * FEATURE1_WEIGHT +
        features[2] * FEATURE2_WEIGHT +
        features[3] * FEATURE3_WEIGHT;

    component featureScoreLeq = LessEqThan(32);
    featureScoreLeq.in[0] <== FEATURE_SCORE_THRESHOLD;
    featureScoreLeq.in[1] <== feature_score;

    within30 <== base.within30;
    distance_ok <== base.distance_ok;
    time_ok <== base.time_ok;
    frame_time_ok <== frameTimeLeq.out;
    model_ok <== featureScoreLeq.out * frame_time_ok;
    within30_and_model <== within30 * model_ok;
}

component main = Distance30mTimeFeatureClassifier(
    11132000,
    9128800,
    10000000,
    3000,
    5,
    12,
    20,
    15,
    18,
    1800
);

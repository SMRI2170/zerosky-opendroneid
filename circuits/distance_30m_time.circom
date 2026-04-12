pragma circom 2.1.9;

template Num2Bits(n) {
    signal input in;
    signal output out[n];

    var lc = 0;
    var bit = 1;

    for (var i = 0; i < n; i++) {
        out[i] <-- (in >> i) & 1;
        out[i] * (out[i] - 1) === 0;
        lc += out[i] * bit;
        bit *= 2;
    }

    lc === in;
}

template LessThan(n) {
    signal input in[2];
    signal output out;

    component toBits = Num2Bits(n + 1);
    toBits.in <== in[0] + (1 << n) - in[1];
    out <== 1 - toBits.out[n];
}

template LessEqThan(n) {
    signal input in[2];
    signal output out;

    component lt = LessThan(n);
    lt.in[0] <== in[0];
    lt.in[1] <== in[1] + 1;
    out <== lt.out;
}

template AbsDiff(n) {
    signal input a;
    signal input b;
    signal output out;
    signal left_term;
    signal right_term;

    component aLtB = LessThan(n);
    component bLtA = LessThan(n);

    aLtB.in[0] <== a;
    aLtB.in[1] <== b;
    bLtA.in[0] <== b;
    bLtA.in[1] <== a;

    left_term <== (b - a) * aLtB.out;
    right_term <== (a - b) * bLtA.out;
    out <== left_term + right_term;
}

template Distance30mTimeWindow(
    LAT_CM_NUM,
    LON_CM_NUM,
    GEO_DEN,
    DISTANCE_LIMIT_CM,
    TIME_LIMIT_SEC
) {
    signal input drone_lat_e7_norm;
    signal input drone_lon_e7_norm;
    signal input drone_alt_cm;
    signal input drone_time_sec;

    signal input target_lat_e7_norm;
    signal input target_lon_e7_norm;
    signal input target_alt_cm;
    signal input target_time_sec;

    signal output within30;
    signal output distance_ok;
    signal output time_ok;

    component dLat = AbsDiff(32);
    component dLon = AbsDiff(32);
    component dAlt = AbsDiff(32);
    component dTime = AbsDiff(64);

    dLat.a <== drone_lat_e7_norm;
    dLat.b <== target_lat_e7_norm;
    dLon.a <== drone_lon_e7_norm;
    dLon.b <== target_lon_e7_norm;
    dAlt.a <== drone_alt_cm;
    dAlt.b <== target_alt_cm;
    dTime.a <== drone_time_sec;
    dTime.b <== target_time_sec;

    signal lat_scaled;
    signal lon_scaled;
    signal alt_scaled;
    signal distance_scaled_sq;
    signal max_distance_scaled_sq;
    signal lat_sq;
    signal lon_sq;
    signal alt_sq;

    lat_scaled <== dLat.out * LAT_CM_NUM;
    lon_scaled <== dLon.out * LON_CM_NUM;
    alt_scaled <== dAlt.out * GEO_DEN;

    lat_sq <== lat_scaled * lat_scaled;
    lon_sq <== lon_scaled * lon_scaled;
    alt_sq <== alt_scaled * alt_scaled;
    distance_scaled_sq <== lat_sq + lon_sq + alt_sq;
    max_distance_scaled_sq <== (DISTANCE_LIMIT_CM * GEO_DEN) * (DISTANCE_LIMIT_CM * GEO_DEN);

    component distanceLeq = LessEqThan(128);
    distanceLeq.in[0] <== distance_scaled_sq;
    distanceLeq.in[1] <== max_distance_scaled_sq;
    distance_ok <== distanceLeq.out;

    component timeLeq = LessEqThan(64);
    timeLeq.in[0] <== dTime.out;
    timeLeq.in[1] <== TIME_LIMIT_SEC;
    time_ok <== timeLeq.out;

    within30 <== distance_ok * time_ok;
}

component main = Distance30mTimeWindow(
    11132000,
    9128800,
    10000000,
    3000,
    5
);

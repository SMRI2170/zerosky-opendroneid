import 'dart:async';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  runApp(const BarometerApp());
}

class BarometerApp extends StatelessWidget {
  const BarometerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Barometer Accuracy Checker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const BarometerScreen(),
    );
  }
}

class BarometerScreen extends StatefulWidget {
  const BarometerScreen({super.key});

  @override
  State<BarometerScreen> createState() => _BarometerScreenState();
}

class _BarometerScreenState extends State<BarometerScreen> {
  static const int _maxDataPoints = 100;
  
  double _currentPressure = 0.0;
  double _minPressure = double.infinity;
  double _maxPressure = double.negativeInfinity;
  double _sumPressure = 0.0;
  int _readingsCount = 0;
  final List<MapEntry<DateTime, double>> _trailing30sData = [];

  final List<FlSpot> _pressureData = [];
  final List<FlSpot> _altitudeData = [];
  double _xValue = 0;

  StreamSubscription<BarometerEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  void _startListening() {
    _subscription = barometerEventStream().listen((BarometerEvent event) {
      if (!mounted) return;
      setState(() {
        _currentPressure = event.pressure;
        
        if (_currentPressure < _minPressure) _minPressure = _currentPressure;
        if (_currentPressure > _maxPressure) _maxPressure = _currentPressure;
        
        _sumPressure += _currentPressure;
        _readingsCount++;

        final now = DateTime.now();
        _trailing30sData.add(MapEntry(now, _currentPressure));
        _trailing30sData.removeWhere((entry) => now.difference(entry.key).inSeconds > 30);

        _pressureData.add(FlSpot(_xValue, _currentPressure));
        _altitudeData.add(FlSpot(_xValue, _estimatedAltitude));
        _xValue += 1;

        if (_pressureData.length > _maxDataPoints) {
          _pressureData.removeAt(0);
          _altitudeData.removeAt(0);
        }
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _resetData() {
    setState(() {
      _currentPressure = 0.0;
      _minPressure = double.infinity;
      _maxPressure = double.negativeInfinity;
      _sumPressure = 0.0;
      _readingsCount = 0;
      _trailing30sData.clear();
      _pressureData.clear();
      _altitudeData.clear();
      _xValue = 0;
    });
  }

  double get _averagePressure {
    if (_trailing30sData.isEmpty) return 0.0;
    double sum = _trailing30sData.fold(0.0, (prev, element) => prev + element.value);
    return sum / _trailing30sData.length;
  }

  double get _estimatedAltitude => _currentPressure > 0
      ? 44330.0 * (1.0 - pow(_currentPressure / 1013.25, 1 / 5.255))
      : 0.0;

  double get _averageAltitude30s {
    double avgP = _averagePressure;
    return avgP > 0 ? 44330.0 * (1.0 - pow(avgP / 1013.25, 1 / 5.255)) : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Barometer Monitor'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset Data',
            onPressed: _resetData,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCurrentPressureCard(),
            const SizedBox(height: 16),
            _buildStatsCard(),
            const SizedBox(height: 24),
            Expanded(
              child: _buildChart(context),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _buildAltitudeChart(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentPressureCard() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const Text(
              'Current Pressure',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '${_currentPressure.toStringAsFixed(2)} hPa',
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Estimated Altitude (30s Avg)',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(
              '${_averageAltitude30s.toStringAsFixed(1)} m',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: Colors.blueGrey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 24.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildStatItem('Min (hPa)', _minPressure == double.infinity ? 0 : _minPressure),
            _buildStatItem('Avg (hPa)', _averagePressure),
            _buildStatItem('Max (hPa)', _maxPressure == double.negativeInfinity ? 0 : _maxPressure),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, double value) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value.toStringAsFixed(2),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildChart(BuildContext context) {
    if (_pressureData.isEmpty) {
      return const Center(child: Text('Waiting for data...'));
    }

    double minY = max(0, _minPressure - 0.5);
    double maxY = _maxPressure + 0.5;

    if (_minPressure == double.infinity) {
      minY = 0;
      maxY = 1100;
    } else if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Pressure Fluctuations',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: true),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 60,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            value.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12),
                          );
                        },
                      ),
                    ),
                    bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  borderData: FlBorderData(show: true),
                  minX: _pressureData.first.x,
                  maxX: _pressureData.last.x,
                  minY: minY,
                  maxY: maxY,
                  lineBarsData: [
                    LineChartBarData(
                      spots: _pressureData,
                      isCurved: true,
                      color: Colors.blueAccent,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blueAccent.withValues(alpha: 0.2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAltitudeChart(BuildContext context) {
    if (_altitudeData.isEmpty) {
      return const Center(child: Text('Waiting for data...'));
    }

    double minAlt = _maxPressure == double.negativeInfinity ? 0.0 : 44330.0 * (1.0 - pow(_maxPressure / 1013.25, 1 / 5.255));
    double maxAlt = _minPressure == double.infinity ? 0.0 : 44330.0 * (1.0 - pow(_minPressure / 1013.25, 1 / 5.255));

    double minY = minAlt - 2.0;
    double maxY = maxAlt + 2.0;

    if (_minPressure == double.infinity) {
      minY = -100;
      maxY = 8000;
    } else if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Altitude Fluctuations',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: true),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 60,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            value.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12),
                          );
                        },
                      ),
                    ),
                    bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  borderData: FlBorderData(show: true),
                  minX: _altitudeData.first.x,
                  maxX: _altitudeData.last.x,
                  minY: minY,
                  maxY: maxY,
                  lineBarsData: [
                    LineChartBarData(
                      spots: _altitudeData,
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.green.withValues(alpha: 0.2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

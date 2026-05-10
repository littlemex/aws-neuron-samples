#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { NeuronCodeServerStack } from '../lib/torch-neuron-stack';

const app = new cdk.App();

const stackName = app.node.tryGetContext('stackName') || 'neuron-code-server';
const instanceType = app.node.tryGetContext('instanceType') || 'trn2.3xlarge';
const useCapacityBlock = app.node.tryGetContext('useCapacityBlock') === 'true';
const capacityReservationId = app.node.tryGetContext('capacityReservationId') || '';
const useSpot = app.node.tryGetContext('useSpot') === 'true';
const spotMaxPrice = app.node.tryGetContext('spotMaxPrice') || '';
const spotInterruptionBehavior =
  app.node.tryGetContext('spotInterruptionBehavior') || 'terminate';
const subnetId = app.node.tryGetContext('subnetId') || '';
const volumeSize = parseInt(app.node.tryGetContext('volumeSize') || '500');
const efsId = app.node.tryGetContext('efsId') || '';
const efsSubpath = app.node.tryGetContext('efsSubpath') || '/neuron-workspace';
const project = app.node.tryGetContext('project') || '';
const purpose = app.node.tryGetContext('purpose') || '';

if (useCapacityBlock && useSpot) {
  throw new Error(
    'useCapacityBlock and useSpot are mutually exclusive. Choose one.'
  );
}

new NeuronCodeServerStack(app, stackName, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  instanceType,
  useCapacityBlock,
  capacityReservationId,
  useSpot,
  spotMaxPrice,
  spotInterruptionBehavior,
  subnetId,
  volumeSize,
  efsId,
  efsSubpath,
  project: project || undefined,
  purpose: purpose || undefined,
});

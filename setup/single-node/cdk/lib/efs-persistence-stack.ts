import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as efs from 'aws-cdk-lib/aws-efs';
import { Construct } from 'constructs';

export interface EfsPersistenceStackProps extends cdk.StackProps {
  /**
   * Performance mode for the file system.
   * generalPurpose handles dev workloads fine; switch to maxIO only if you
   * see throughput saturation across many parallel readers.
   */
  readonly performanceMode?: efs.PerformanceMode;

  /**
   * Throughput mode. `elastic` auto-scales and is the safest default for
   * dev workloads of varying intensity. `bursting` is cheaper at idle.
   */
  readonly throughputMode?: efs.ThroughputMode;

  /**
   * Encrypt at rest with a KMS key. Defaults to true (AWS-managed key).
   * Set false only if your environment forbids KMS.
   */
  readonly encrypted?: boolean;

  /**
   * Lifecycle policy: when to transition rarely-accessed files to IA tier.
   * Default: AFTER_30_DAYS — meaningful savings without surprising performance.
   */
  readonly lifecyclePolicy?: efs.LifecyclePolicy;

  /**
   * RemovalPolicy for the file system. RETAIN by default — we keep the
   * file system across `cdk destroy` so model caches and HF downloads
   * survive region switches and Spot reclaim cycles.
   * Pass cdk.RemovalPolicy.DESTROY explicitly only when you really want
   * to wipe the data and stop EFS billing.
   */
  readonly removalPolicy?: cdk.RemovalPolicy;

  /** Optional free-form tag applied to all resources. */
  readonly project?: string;
  readonly purpose?: string;
}

/**
 * Standalone CDK stack that provisions an EFS file system + mount targets
 * in the default VPC of the current region. It does NOT touch the EC2 SG;
 * NFS ingress (TCP 2049) is opened by deploy.sh after both stacks are up,
 * matching the existing manage-security-group.sh contract.
 *
 * Why a separate stack:
 *   - EFS lifecycle is independent from the EC2 host. Destroying the EC2
 *     stack must not delete the file system that contains compiled NEFF
 *     caches and HuggingFace downloads.
 *   - When a Spot instance is reclaimed and re-deployed, the EFS stack
 *     stays put; the new instance re-mounts the same file system.
 *
 * Outputs:
 *   - EfsId
 *   - EfsArn
 *   - EfsMountTargetSecurityGroupId  (used by deploy.sh to authorize NFS
 *                                     ingress from the EC2 SG)
 */
export class EfsPersistenceStack extends cdk.Stack {
  public readonly fileSystem: efs.FileSystem;
  public readonly mountTargetSecurityGroup: ec2.SecurityGroup;

  constructor(scope: Construct, id: string, props: EfsPersistenceStackProps) {
    super(scope, id, props);

    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });

    // EFS mount-target SG: zero ingress at creation. deploy.sh adds an NFS
    // (TCP 2049) ingress rule that allows the EC2 instance SG only. This
    // keeps the contract consistent with manage-security-group.sh and
    // avoids opening NFS to the VPC at large.
    this.mountTargetSecurityGroup = new ec2.SecurityGroup(this, 'EfsMtSg', {
      vpc,
      description:
        'EFS mount target SG (zero ingress at create; deploy.sh authorizes ' +
        'NFS 2049 ingress from the EC2 SG of each consuming stack).',
      allowAllOutbound: true,
    });

    this.fileSystem = new efs.FileSystem(this, 'FileSystem', {
      vpc,
      // mount-target SG is supplied explicitly so deploy.sh can find and
      // mutate it post-deploy.
      securityGroup: this.mountTargetSecurityGroup,
      // Default VPC's public subnets live in every AZ; CDK creates one
      // mount target per AZ which is what we want for fault tolerance.
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      performanceMode: props.performanceMode ?? efs.PerformanceMode.GENERAL_PURPOSE,
      throughputMode: props.throughputMode ?? efs.ThroughputMode.ELASTIC,
      encrypted: props.encrypted ?? true,
      lifecyclePolicy: props.lifecyclePolicy ?? efs.LifecyclePolicy.AFTER_30_DAYS,
      // RETAIN: cdk destroy で EFS を消さない。リージョン切替や Spot 再起動を
      // 多発させても model キャッシュ等が残るようにする。手動で消す場合は
      //   aws efs delete-file-system --file-system-id <fs-...>
      removalPolicy: props.removalPolicy ?? cdk.RemovalPolicy.RETAIN,
    });

    if (props.project) cdk.Tags.of(this).add('Project', props.project);
    if (props.purpose) cdk.Tags.of(this).add('Purpose', props.purpose);

    new cdk.CfnOutput(this, 'EfsId', {
      value: this.fileSystem.fileSystemId,
      description: 'EFS file system id (pass to deploy.sh --efs-id)',
      exportName: `${id}-EfsId`,
    });

    new cdk.CfnOutput(this, 'EfsArn', {
      value: this.fileSystem.fileSystemArn,
      description: 'EFS file system ARN',
    });

    new cdk.CfnOutput(this, 'EfsMountTargetSecurityGroupId', {
      value: this.mountTargetSecurityGroup.securityGroupId,
      description: 'SG used by EFS mount targets; deploy.sh adds NFS ingress',
    });
  }
}

import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import * as fs from 'fs';
import * as path from 'path';

export interface NeuronCodeServerStackProps extends cdk.StackProps {
  instanceType: string;
  useCapacityBlock: boolean;
  capacityReservationId: string;
  useSpot: boolean;
  spotMaxPrice: string;
  spotInterruptionBehavior: string;
  subnetId: string;
  volumeSize: number;
  efsId: string;
  efsSubpath: string;
  /** Optional free-form tag applied to the instance (example: "my-team"). */
  project?: string;
  /** Optional free-form tag applied to the instance (example: "training"). */
  purpose?: string;
}

interface Config {
  regions: {
    [key: string]: {
      amiSsmParameter: string;
      defaultEfsId?: string;
    };
  };
  defaultVolumeSize: number;
  codeServerUser: string;
  homeFolder: string;
}

/**
 * Single EC2 instance running a Neuron-ready DLAMI with code-server,
 * nginx, persistent EFS, and SSM-only network access.
 *
 * Design notes:
 *   - The security group has no ingress rules. Access to code-server is
 *     exclusively through SSM Session Manager port forwarding
 *     (AWS-StartPortForwardingSession). This avoids exposing an
 *     unauthenticated HTTP endpoint on a public IP, which tends to be
 *     flagged by public-endpoint security scanners.
 *   - Filesystem setup (EFS mount, symlinks under /home, NEFF compile
 *     cache) is intentionally NOT performed in user-data. User-data only
 *     runs on first boot and is not re-executed after Spot stop/start,
 *     whereas the NVMe instance store is wiped across stops. Setup is
 *     driven by the SSM Run Command task in tasks/code-server-setup.json
 *     so it can be re-run on demand.
 */
export class NeuronCodeServerStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: NeuronCodeServerStackProps) {
    super(scope, id, props);

    const configPath = path.join(__dirname, '..', 'config.json');
    const config: Config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));

    const region = this.region;
    const regionConfig = config.regions[region];

    if (!regionConfig) {
      throw new Error(`Region ${region} is not configured in config.json`);
    }

    // AMI SSM parameter resolution:
    //   1. Environment variable NEURON_AMI_SSM_PARAMETER overrides anything
    //      (opt-in path for pre-release / beta DLAMIs).
    //   2. Otherwise use the public parameter defined in config.json.
    // The public default always resolves to the latest GA Neuron DLAMI for
    // Ubuntu 24.04. To use a different AMI (custom, private, or beta),
    // export NEURON_AMI_SSM_PARAMETER=<parameter-name> before running cdk.
    const amiSsmParameter =
      process.env.NEURON_AMI_SSM_PARAMETER || regionConfig.amiSsmParameter;

    // EFS ID resolution order:
    //   props.efsId === 'none'    -> EFS disabled (passed explicitly via --no-efs)
    //   props.efsId set           -> use it
    //   props.efsId empty         -> fall back to regionConfig.defaultEfsId (optional)
    const efsId =
      props.efsId === 'none'
        ? ''
        : props.efsId || regionConfig.defaultEfsId || '';
    const efsSubpath = props.efsSubpath || '/neuron-workspace';

    // Password for code-server, auto-generated and stored in Secrets Manager.
    const password = new secretsmanager.Secret(this, 'CodeServerPassword', {
      description: 'code-server password',
      generateSecretString: {
        excludePunctuation: true,
        passwordLength: 16,
      },
    });

    // IAM role for the instance.
    //
    // The default policy set is intentionally narrow: SSM agent registration
    // and CloudWatch agent. Grant any additional permissions your workload
    // needs explicitly - do NOT attach AdministratorAccess for production use.
    // For interactive development it can be convenient to attach broader
    // policies, but that is left to the operator to decide.
    const role = new iam.Role(this, 'CodeServerInstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
      ],
    });

    const instanceProfile = new iam.CfnInstanceProfile(this, 'CodeServerInstanceProfile', {
      roles: [role.roleName],
    });

    // Security group with no ingress. Outbound is allowed (needed for apt,
    // pip, ECR, and the SSM agent). See the class comment for rationale.
    const securityGroup = new ec2.SecurityGroup(this, 'CodeServerSecurityGroup', {
      vpc: ec2.Vpc.fromLookup(this, 'VPC', { isDefault: true }),
      description:
        'Security group for code-server (SSM-only, no ingress). Access via aws ssm start-session port forwarding.',
      allowAllOutbound: true,
    });

    const amiId = ec2.MachineImage.fromSsmParameter(amiSsmParameter, {
      os: ec2.OperatingSystemType.LINUX,
    }).getImage(this).imageId;

    // Minimal user-data: stamp a log file. Real setup runs later via SSM
    // Run Command (see tasks/code-server-setup.json).
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -e',
      'echo "[user-data] start $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a /var/log/neuron-user-data.log',
      'echo "[user-data] filesystem + code-server setup runs through" | tee -a /var/log/neuron-user-data.log',
      'echo "[user-data] scripts/setup-code-server.sh (SSM Run Command)" | tee -a /var/log/neuron-user-data.log',
      `CODE_USER='${config.codeServerUser}'`,
      `HOME_DIR='${config.homeFolder}'`,
      `EFS_ID='${efsId}'`,
      `EFS_SUBPATH='${efsSubpath}'`,
      `REGION='${this.region}'`,
      'echo "[user-data] done $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a /var/log/neuron-user-data.log',
    );

    const launchTemplateData: any = {
      imageId: amiId,
      instanceType: props.instanceType,
      blockDeviceMappings: [
        {
          deviceName: '/dev/sda1',
          ebs: {
            volumeSize: props.volumeSize,
            volumeType: 'gp3',
            deleteOnTermination: true,
            encrypted: true,
          },
        },
      ],
      monitoring: {
        enabled: true,
      },
      iamInstanceProfile: {
        arn: instanceProfile.attrArn,
      },
      securityGroupIds: [securityGroup.securityGroupId],
      userData: cdk.Fn.base64(userData.render()),
      tagSpecifications: [
        {
          resourceType: 'instance',
          tags: [
            {
              key: 'Name',
              value: id,
            },
          ],
        },
      ],
    };

    // Defence-in-depth: the CLI wrapper also validates this. See bin/app.ts.
    if (props.useCapacityBlock && props.useSpot) {
      throw new Error(
        'useCapacityBlock and useSpot cannot be enabled simultaneously.'
      );
    }

    if (props.useCapacityBlock) {
      launchTemplateData.instanceMarketOptions = {
        marketType: 'capacity-block',
      };
    }

    if (props.capacityReservationId) {
      launchTemplateData.capacityReservationSpecification = {
        capacityReservationTarget: {
          capacityReservationId: props.capacityReservationId,
        },
      };
    }

    // Spot configuration.
    //
    // AWS EC2 requires specific combinations of spotInstanceType and
    // instanceInterruptionBehavior:
    //   - 'one-time'   pairs with 'terminate' only
    //   - 'persistent' is required for 'stop' or 'hibernate'
    // Trying to use 'one-time' with 'stop' returns:
    //   "The request with type 'one-time' is not supported when
    //    instanceInterruptionBehavior is set to 'STOP'".
    if (props.useSpot) {
      const behavior = (props.spotInterruptionBehavior || 'terminate').toLowerCase();
      const spotInstanceType = behavior === 'terminate' ? 'one-time' : 'persistent';
      const spotOptions: any = {
        spotInstanceType,
        instanceInterruptionBehavior: behavior,
      };
      if (props.spotMaxPrice) {
        spotOptions.maxPrice = props.spotMaxPrice;
      }
      launchTemplateData.instanceMarketOptions = {
        marketType: 'spot',
        spotOptions,
      };
    }

    const launchTemplate = new ec2.CfnLaunchTemplate(this, 'CodeServerLaunchTemplate', {
      launchTemplateName: `${id}-LaunchTemplate`,
      launchTemplateData,
    });

    launchTemplate.node.addDependency(instanceProfile);
    launchTemplate.node.addDependency(securityGroup);

    const instance = new ec2.CfnInstance(this, 'CodeServerInstance', {
      launchTemplate: {
        launchTemplateId: launchTemplate.ref,
        version: launchTemplate.attrLatestVersionNumber,
      },
      subnetId: props.subnetId || undefined,
      tags: [
        {
          key: 'Name',
          value: id,
        },
        {
          key: 'ManagedBy',
          value: 'CDK',
        },
        {
          key: 'CapacityBlock',
          value: props.useCapacityBlock ? 'true' : 'false',
        },
        {
          key: 'MarketType',
          value: props.useCapacityBlock
            ? 'capacity-block'
            : props.useSpot
              ? 'spot'
              : 'on-demand',
        },
        {
          key: 'EfsId',
          value: efsId || 'none',
        },
        ...(props.project ? [{ key: 'Project', value: props.project }] : []),
        ...(props.purpose ? [{ key: 'Purpose', value: props.purpose }] : []),
      ],
    });

    // Outputs -----------------------------------------------------------
    new cdk.CfnOutput(this, 'InstanceId', {
      description: 'EC2 instance id',
      value: instance.ref,
    });

    new cdk.CfnOutput(this, 'InstancePublicDnsName', {
      description: 'EC2 instance public DNS name (not reachable externally - SG has no ingress)',
      value: instance.attrPublicDnsName,
    });

    new cdk.CfnOutput(this, 'InstancePublicIp', {
      description: 'EC2 instance public IP (not reachable externally - SG has no ingress)',
      value: instance.attrPublicIp,
    });

    new cdk.CfnOutput(this, 'Password', {
      description: 'code-server login password (Secrets Manager)',
      value: password.secretValue.unsafeUnwrap(),
    });

    new cdk.CfnOutput(this, 'SSMConnectCommand', {
      description: 'SSM shell session command',
      value: `aws ssm start-session --target ${instance.ref} --region ${this.region}`,
    });

    new cdk.CfnOutput(this, 'EfsId', {
      description: 'EFS file system id used for /home/coder and /work persistence',
      value: efsId || 'none',
    });

    new cdk.CfnOutput(this, 'EfsSubpath', {
      description: 'Subpath inside the EFS used by this stack',
      value: efsSubpath,
    });

    // Exposed so deploy.sh can automatically authorize NFS (2049) from this
    // SG on the EFS mount target security groups.
    new cdk.CfnOutput(this, 'SecurityGroupId', {
      description: 'EC2 instance security group id (used to open NFS ingress on EFS MT SG)',
      value: securityGroup.securityGroupId,
    });
  }
}

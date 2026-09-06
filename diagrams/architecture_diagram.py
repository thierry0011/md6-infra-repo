"""
Diagram-as-code for the To-Do App architecture.

Usage:
    pip install diagrams
    # also install the Graphviz binary (`dot`) for your OS, e.g.:
    #   macOS:   brew install graphviz
    #   Ubuntu:  sudo apt-get install graphviz
    #   Windows: choco install graphviz
    python architecture_diagram.py
    # -> writes architecture.png next to this script
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, ElasticContainerServiceContainer
from diagrams.aws.database import RDS, ElastiCache
from diagrams.aws.devtools import Codepipeline, Codedeploy, Codebuild
from diagrams.aws.general import Users
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import Cloudwatch, Cloudformation
from diagrams.aws.network import ALB, Endpoint, InternetGateway, PublicSubnet, VPC
from diagrams.aws.security import IdentityAndAccessManagementIamPermissions, KMS
from diagrams.onprem.vcs import Github

graph_attr = {
    "fontsize": "14",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
}

with Diagram(
    "To-Do App - AWS Architecture",
    filename="architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
):
    users = Users("End users\n(browser)")

    with Cluster("GitHub"):
        app_repo = Github("md6-app-repo\n(Django, Dockerfile,\ntaskdef/appspec)")
        infra_repo = Github("md6-infra-repo\n(CloudFormation)")

    oidc = IdentityAndAccessManagementIamPermissions("GitHub OIDC role\n(no long-lived keys)")

    with Cluster("VPC (Multi-AZ, 4 dedicated subnet tiers)"):
        igw = InternetGateway("Internet Gateway")

        with Cluster("Public subnets (AZ-a / AZ-b)"):
            alb = ALB("Application\nLoad Balancer")

        with Cluster("App subnets (AZ-a / AZ-b)"):
            with Cluster("ECS Fargate service (1-4 tasks)"):
                svc_blue = ElasticContainerServiceContainer("Blue task set")
                svc_green = ElasticContainerServiceContainer("Green task set")

        with Cluster("Data subnets (AZ-a / AZ-b)"):
            proxy_label = RDS("RDS Proxy")
            db = RDS("RDS PostgreSQL\n(db.t3, single-AZ -\nno standby replica)")

        with Cluster("Cache subnets (AZ-a / AZ-b)"):
            redis = ElastiCache("ElastiCache Redis\n(read cache)")

        with Cluster("VPC Endpoints (no NAT)"):
            vpce = Endpoint("ECR / S3 / Logs /\nSecrets Manager")

    kms = KMS("KMS CMK")

    with Cluster("CI/CD"):
        ecr = ECR("ECR: app image\n(IMMUTABLE tags)")
        eventbridge = Eventbridge("EventBridge rule\n(any ECR push,\ndigest override)")
        pipeline = Codepipeline("CodePipeline")
        migrate = Codebuild("CodeBuild:\nrun migrations")
        codedeploy = Codedeploy("CodeDeploy\n(blue/green)")

    cw = Cloudwatch("CloudWatch Logs\n/ecs/md6-todo")
    cfn = Cloudformation("CloudFormation\n(nested stacks)")

    users >> Edge(label="HTTP") >> alb >> Edge(label=":8000") >> svc_blue
    alb >> Edge(style="dashed", label="test listener") >> svc_green

    igw >> alb

    svc_blue >> Edge(label="R/W (proxy)") >> proxy_label >> db
    svc_blue >> Edge(label="cache") >> redis
    svc_blue >> cw
    db >> Edge(style="dotted") >> kms
    redis >> Edge(style="dotted") >> kms

    app_repo >> Edge(label="OIDC assume-role") >> oidc >> Edge(label="docker push\n(unique tag)") >> ecr
    ecr >> eventbridge >> pipeline
    app_repo >> Edge(label="taskdef.json /\nappspec.yaml", style="dashed") >> pipeline
    pipeline >> migrate >> Edge(label="manage.py migrate") >> proxy_label
    pipeline >> codedeploy >> Edge(label="shift traffic") >> svc_green

    infra_repo >> Edge(label="package + deploy\n(GitHub Actions)", color="darkgreen") >> cfn >> vpce

# Project Details

So why did you create this site?  Was there a purpose?

**Example problem:**   We have a main site [people-poc.aws.mattsnell.com](http://people-poc.aws.mattsnell.com) that is centrally managed.  We want to enable approved contributors to publish community content within our namespace (example: [http://people-poc.aws.mattsnell.com/coffeefans](#)).  

Contributors should be able to create their content and have it published automatically, and we don't want to create significant technical debt in the process!  One other requisite, we need apache to serve these sites, our community values the controls that are enabled by htaccess.

A potential solution is outlined below, it has the benefits of being completely serverless, it enables contributors to take advantage of well known revision control tools and only requires configuration/setup once in an effort to get the ball rolling.

**This is not a walkthrough, there are some assumptions that have been made with regards to existing resources in your account**

**Assumptions:**

* Routing to the sites is a solved problem, what I've done in this example is configure an [Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html) (ALB) with path based routing.  There are rules that forward requests to the appropriate Target Groups and these groups have the appropriate containers as members.
* There is an existing [Amazon Elastic Container Service](https://aws.amazon.com/ecs/) (ECS) cluster that can be used to host the containers created in the example
* The main site and the associated paths (directories) owned by it, are out of scope (that content is managed outside of this process)
* There aren't a lot of these sites so the ramp up and maintenance is measurable and minimal

**A 10,000 foot view of the pipeline:**

1. A contributor updates their site locally and commits those changes to [github](https://github.com/)
1. An [AWS CodePipeline](https://aws.amazon.com/codepipeline/) job is triggered via [webhook](https://developer.github.com/webhooks/); it uses [AWS CodeBuild](https://aws.amazon.com/codebuild/) and creates a docker image and then pushes that image to [AWS Elastic Container Registry](https://aws.amazon.com/ecr/) (ECR)
1. CodePipeline then updates an ECS [service](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs_services.html) which triggers a replacement of the running containers

![Diagram](people-poc.png)

## Repository layout

Take a look at [https://github.com/mattsnell/people-poc-child1](https://github.com/mattsnell/people-poc-child1), this is the user content and is the source of the site data within the container.  

There are two paths to focus on:

| Path | Description |
|------|-------------|
|site/child1| This is the output html, it will be copied to `/var/www/html/child1/` in the container|
|users| This is where the contributor will configure their htpasswd file |

* Notice that the path `child1` is carried forward to the container (required for [path-based routing](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-listeners.html#path-conditions) in [ALB](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html))
* The htpasswd file is outside of the web content (the norm)
* The only path that has htaccess control applied is `site/child1/protected/`.  You can review the .htaccess file there.

## Dockerfile

There are a number of ways to tackle this particular problem.  In this example, I've designed my image from an older CentOS base:

```Dockerfile
FROM centos:6.10

RUN yum update --assumeyes \
    && yum install httpd --assumeyes \
    && yum clean all --quiet --assumeyes \
    && rm -rf /var/cache/yum

COPY --chown=root:root conf/httpd.conf /etc/httpd/conf/
COPY --chown=root:root users/htpasswd /opt/.htpasswd
COPY --chown=root:root site/ /var/www/html/

EXPOSE 80

ENTRYPOINT ["/usr/sbin/httpd", "-e", "DEBUG", "-D", "FOREGROUND"]```
```


## ECR
At this point, create the ECR registry and note the name, perhaps something like `web/child1`.  That value will be needed in the CodeBuild section coming up.

## CodeBuild

Create a [Build Project](https://docs.aws.amazon.com/codebuild/latest/userguide/create-project.html); there are a number of questions to answer and they are grouped by action, some of my responses are below.

| Question | Response |
|----------|----------|
|Source: What to build / Source provider| github |
|Environment: How to build / Environment image | Use an image managed by AWS CodeBuild |
|Environment: How to build / Operating system | Ubuntu |
|Environment: How to build / Runtime | Docker |
|Environment: How to build / Runtime version | aws/codebuild/docker:* |
|Environment: How to build / Build specification | insert build commands (see example buildspec.yml) |
|Service role | Create a service role |
|Advanced Settings | Configure environment variables (more below)|

**Notes:**

* Don't opt to "Rebuild every time a code change is pushed to this repository" (CodePipeline will manage that task)
* I opted to insert the [buildspec.yml](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html) code in the build project so that it doesn't need to be maintained in the contributor's repository
* The service role will need additional permissions (more below)

**Environment Variables:** There are a number of variables that I configured when defining the project to make the buildspec.yml code reuseable:

| Variable              | Description                                                    |
| ----------------------|----------------------------------------------------------------|
| $CONTAINER_NAME | This must match the name you select when you define your ECS service |
| $AWS_DEFAULT_REGION | This is the region you deploy your resources in (us-east-2)      |
| $IMAGE_REPO_NAME | ECR image repository name (web/child1)                              |
| $IMAGE_TAG | The tage you define for your image                                        |
| $AWS_ACCOUNT_ID | The account ID where you're deploying (used when setting ECR URI)    |

**Example buildspec.yml:**  This is the spec file that I used to build the container.  It illustrates the use of the variables I specified above.

```yaml
version: 0.2

phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - $(aws ecr get-login --no-include-email --region $AWS_DEFAULT_REGION)
  build:
    commands:
      - echo Downloading Dockerfile
      - aws s3 cp s3://my-bucket/people-poc-child1/Dockerfile .
      - echo Downloading Apache config
      - mkdir conf
      - aws s3 cp s3://my-bucket/people-poc-child1/httpd.conf conf/
      - echo Build started on `date`
      - echo Building the Docker image...          
      - docker build -t $IMAGE_REPO_NAME:$IMAGE_TAG .
      - docker tag $IMAGE_REPO_NAME:$IMAGE_TAG $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG      
  post_build:
    commands:
      - echo Build completed on `date`
      - echo Pushing the Docker image...
      - docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG
      - echo Creating imagedefinitions.json...
      - printf '[{"name":"%s","imageUri":"%s"}]' $CONTAINER_NAME $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME:$IMAGE_TAG > imagedefinitions.json
      - cat imagedefinitions.json
artifacts:
  files:
    - imagedefinitions.json
```

**Permissions:**  Finally, the service role created (earlier) will need the ability to interact with ECR and S3, I opted to do this with two inline policies.  These are somewhat over-permissive, noted!

**ECR:**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "ecr:BatchCheckLayerAvailability",
                "ecr:CompleteLayerUpload",
                "ecr:GetAuthorizationToken",
                "ecr:InitiateLayerUpload",
                "ecr:PutImage",
                "ecr:UploadLayerPart"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
    ]
}
```

**S3:**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "cb-s3-read",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucketByTags",
                "s3:GetLifecycleConfiguration",
                "s3:GetBucketTagging",
                "s3:GetInventoryConfiguration",
                "s3:GetObjectVersionTagging",
                "s3:ListBucketVersions",
                "s3:GetBucketLogging",
                "s3:GetAccelerateConfiguration",
                "s3:GetBucketPolicy",
                "s3:GetObjectVersionTorrent",
                "s3:GetObjectAcl",
                "s3:GetEncryptionConfiguration",
                "s3:GetBucketRequestPayment",
                "s3:GetObjectVersionAcl",
                "s3:GetObjectTagging",
                "s3:GetMetricsConfiguration",
                "s3:GetIpConfiguration",
                "s3:ListBucketMultipartUploads",
                "s3:GetBucketWebsite",
                "s3:GetBucketVersioning",
                "s3:GetBucketAcl",
                "s3:GetBucketNotification",
                "s3:GetReplicationConfiguration",
                "s3:ListMultipartUploadParts",
                "s3:GetObject",
                "s3:GetObjectTorrent",
                "s3:GetBucketCORS",
                "s3:GetAnalyticsConfiguration",
                "s3:GetObjectVersionForReplication",
                "s3:GetBucketLocation",
                "s3:GetObjectVersion"
            ],
            "Resource": "*"
        }
    ]
}
```

At this point, test the build.  Once complete, the ECR image will be available for use in the next step

## ECS

Create a new task definition and service.  Again, this assumes there is an ECS cluster with resources available to host the containers.

Task definition:

* Add a new task definition of type **EC2**
* Create task and execution roles as required
* Configure task memory and CPU as required
* When adding a container to the definition, the name **must** match the value of the CONTAINER_NAME variable in your CodeBuild project, you will need to provide the full URI to the image in ECR as well
* Configure other values as required

Service:

* Launch type is EC2, configure other service and placement options as required
* Configure load balancing as required (in this example, I'm using an ALB and target groups that aren't detailed here)
* Adjust Service Auto Scaling as required

## CodePipeline

Now to tie it all together in CodePipeline

Create a new pipeline

| Question | Response |
|----------|----------|
|Source provider | github |
|Repository | Select your repo (authorize access if required) |
|Branch | master (or your choice)|
|Build provider | AWS CodeBuild |
|Select an existing build project | select the build project created earlier |
|Deployment Provider | Amazon ECS |
|Cluster Name | your cluster |
|Service Name | provide the service created earlier |
|Image filename | imagedefinitions.json |

Notes:

* The imagedefinitions.json file is created as part of the build process (see the buildspec.yml file and [Tutorial: Continuous Deployment with AWS CodePipeline](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-cd-pipeline.html) for more detail)
* Create service role as required
* CodePipeline will create or re-use an S3 bucket to store artifacts for this pipeline

## Costs

Pricing info may be stale!  This information below is accurate as of 2018/10/03, visit the pricing pages for updates

### CodeBuild

See [CodeBuild pricing](https://aws.amazon.com/codebuild/pricing/)

* Building this project takes roughly 1 minute on a build.general1.small at $0.005 per build minute
* The AWS CodeBuild free tier includes 100 build minutes of build.general1.small per month. The CodeBuild free tier does not expire automatically at the end of your 12-month AWS Free Tier term. It is available to new and existing AWS customers.

### CodePipeline

See [CodePipeline pricing](https://aws.amazon.com/codepipeline/pricing/)

* With AWS CodePipeline, there are no upfront fees or commitments. You pay only for what you use. AWS CodePipeline costs $1 per active pipeline* per month. To encourage experimentation, pipelines are free for the first 30 days after creation.
* An active pipeline is a pipeline that has existed for more than 30 days and has at least one code change that runs through it during the month. There is no charge for pipelines that have no new code changes running through them during the month. An active pipeline is not prorated for partial months.

### ECS Pricing

See [ECS pricing](https://aws.amazon.com/ecs/pricing/)

There is no additional charge for EC2 launch type. You pay for AWS resources (e.g. EC2 instances or EBS volumes) you create to store and run your application.

### ECR Pricing 

See [ECR pricing](https://aws.amazon.com/ecr/pricing/)

* Storage is $0.10 per GB-month, the image for this project was about 100MB
* Data Transfer Out (in is $0) - Up to 1 GB / Month	is $0.00 per GB, Next 9.999 TB / Month is $0.09 per GB

### S3 Pricing

See [S3 pricing](https://aws.amazon.com/s3/pricing/)

Some data is written to S3 and will count towards your monthly S3 charges

* Dockerfile and httpd.conf - ~35KB of storage
* CodePipine will save some artifacts to S3, size will vary based on the sites being built (this example consumed ~2MB of S3 storage per build)
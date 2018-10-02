# Project Details

So why did you create this site?  Was there a purpose?

**Example problem:**   We have a main site [people-poc.aws.mattsnell.com](http://people-poc.aws.mattsnell.com) that is centrally managed.  We want to enable approved contributors to publish community content within our namespace (example: [http://people-poc.aws.mattsnell.com/coffeefans](#)).  Contributors should be able to create their content and have it published automatically, and we don't want to create significant technical debt in the process!  One other requisite, we need apache to serve these sites, our community values the controls that are enabled by htaccess.

A potential solution is outlined below, it has the benefits of being completely serverless, it enables the contributors to take advantage of well known revision control tools and only configuration/setup once to get the ball rolling.

**Assumptions:**
* Routing to the sites is a solved problem, what I've done to make this work is configure an Application Load Balancer (ALB) with path based routing.  There are rules that forward requests to the appropriate Target Groups and these groups have the appropriate containers as members.
* There is existing ECS infrastructure that can be used to host the containers created below
* The main site and the associated paths owned by it are out of scope (that content is managed outside of this process)
* There aren't a lot of these sites so the ramp up and maintenance is measurable and minimal

**A 10,000 foot view of the pipeline:**
1.  A contributor updates their site locally and commits those changes to github
1. An AWS CodePipeline job is triggered via webhook; it uses AWS CodeBuild and creates a docker container and pushes it to AWS Elastic Container Registry (ECR)
1. An AWS Elastic Container Service (ECS) service is updated using the updated image triggering a replacment of the running containers

![Diagram](people-poc.png)

## Repository layout


## Docker Image
There are a number of ways to tackle this particular problem.  In this case I designed my image from an older CentOS base:
```
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

NEED TO MOVE httpd.conf to the S3 bucket and update buildspec.yml - shouldn't be exposed to user

## ECR
Create your ECR repository and make note of the name

## CodeBuild

Create Build Project

There are a number of variables that I used when defining the project to make it reusable.

* $CONTAINER_NAME
* $AWS_DEFAULT_REGION
* $IMAGE_REPO_NAME
* $IMAGE_TAG
* $AWS_ACCOUNT_ID

**Example buildspec.yml**
```
version: 0.2

phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - $(aws ecr get-login --no-include-email --region $AWS_DEFAULT_REGION)
  build:
    commands:
      - echo Downloading Dockerfile
      - aws s3 cp s3://aws-mds-data/bu/dev/people-poc-child1/Dockerfile .
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

## ECS
Create a new service

## CodePipeline
Tie it all together!
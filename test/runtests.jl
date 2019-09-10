using Mocking
Mocking.enable(force=true)

using AWSBatch
using AWSClusterManagers
using AWSClusterManagers: launch_timeout, desired_workers
using AWSTools.CloudFormation: stack_output
using AWSTools.Docker: Docker
using Base: AbstractCmd
using Dates
using Distributed
using LibGit2
using Memento
using Memento.TestUtils: @test_log
using Printf: @sprintf
using Sockets
using Test

logger = Memento.config!("info"; fmt="[{level} | {name}]: {msg}")

const PKG_DIR = abspath(@__DIR__, "..")

# Enables the running of the "docker" and "batch" online tests. e.g ONLINE=docker,batch
const ONLINE = split(strip(get(ENV, "ONLINE", "")), r"\s*,\s*"; keepempty=false)

# Run the tests on a stack created with the "test/batch.yml" CloudFormation template
const AWS_STACKNAME = get(ENV, "AWS_STACKNAME", "")
const STACK = !isempty(AWS_STACKNAME) ? stack_output(AWS_STACKNAME) : Dict()
const ECR = !isempty(STACK) ? first(split(STACK["EcrUri"], ':')) : "aws-cluster-managers-test"

const GIT_DIR = joinpath(@__DIR__, "..", ".git")
const REV = if isdir(GIT_DIR)
    try
        readchomp(`git --git-dir $GIT_DIR rev-parse --short HEAD`)
    catch
        # Fallback to using the full SHA when git is not installed
        LibGit2.with(LibGit2.GitRepo(GIT_DIR)) do repo
            string(LibGit2.GitHash(LibGit2.GitObject(repo, "HEAD")))
        end
    end
else
    # Fallback when package is not a git repository. Only should occur when running tests
    # from inside a Docker container produced by the Dockerfile for this package.
    "latest"
end

const TEST_IMAGE = "$ECR:$REV"
const BASE_IMAGE = "468665244580.dkr.ecr.us-east-1.amazonaws.com/julia-baked:1.0"

function registry_id(image::AbstractString)
    m = match(r"^\d+", image)
    return m.match
end

# Note: By building the Docker image prior to running any tests (instead of just before the
# image is required) we avoid having a Docker build log breaking up output from tests.
if !isempty(ONLINE)
    @info("Preparing Docker image for online tests")

    # If the AWSClusterManager tests are being executed from within a container we will
    # assume that the image currently in use should be used for online tests.
    if !isempty(AWSClusterManagers.container_id())
        run(`docker tag $(AWSClusterManagers.image_id()) $TEST_IMAGE`)
    else
        Docker.login(registry_id(BASE_IMAGE))
        Docker.pull(BASE_IMAGE)
        run(`docker build -t $TEST_IMAGE --build-arg BASE_IMAGE=$BASE_IMAGE $PKG_DIR`)
    end

    # Push the image to ECR if the online tests require it. Note: `TEST_IMAGE` is required
    # to be a full URI in order for the push operation to succeed.
    if "batch" in ONLINE
        Docker.login(registry_id(TEST_IMAGE))
        Docker.push(TEST_IMAGE)
    end
end


@testset "AWSClusterManagers" begin
    include("container.jl")
    include("docker.jl")
    include("batch.jl")
end

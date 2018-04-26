import Base: ==
import Base: showerror
using AWSSDK.Batch: describe_job_queues, describe_compute_environments

# Seconds to wait for the AWS Batch cluster to scale up, spot requests to be fufilled,
# instances to finish initializing, and have the worker instances connect to the manager.
const BATCH_TIMEOUT = 900  # 15 minutes

struct BatchEnvironmentError <: Exception
    message::String
end

function showerror(io::IO, e::BatchEnvironmentError)
    print(io, "BatchEnvironmentError: ")
    print(io, e.message)
end

# Note: Communication directly between AWS Batch jobs works since the underlying ECS task
# implicitly uses networkMode: host. If this changes to another networking mode AWS Batch
# jobs may no longer be able to listen to incoming connections.

"""
    AWSBatchManager(max_workers; kwargs...)
    AWSBatchManager(min_workers:max_workers; kwargs...)
    AWSBatchManager(min_workers, max_workers; kwargs...)

A cluster manager which spawns workers via [Amazon Web Services Batch](https://aws.amazon.com/batch/)
service. Typically used within an AWS Batch job to add additional resources. The number of
workers spawned may be potentially be lower than the requested `max_workers` due to resource
contention. Specifying `min_workers` can allow the launch to succeed with less than the
requested `max_workers`.

## Arguments
- `min_workers::Int`: The minimum number of workers to spawn or an exception is thrown
- `max_workers::Int`: The number of requested workers to spawn

## Keywords
- `definition::AbstractString`: Name of the AWS Batch job definition which dictates
  properties of the job including the Docker image, IAM role, and command to run
- `name::AbstractString`: Name of the job inside of AWS Batch
- `queue::AbstractString`: The job queue in which workers are submitted. Can be either the
  queue name or the Amazon Resource Name (ARN) of the queue. If not set will default to
  the environmental variable "WORKER_JOB_QUEUE".
- `memory::Integer`: Memory limit (in MiB) for the job container. The container will be killed
  if it exceeds this value.
- `region::AbstractString`: The region in which the API requests are sent and in which new
  worker are spawned. Defaults to "us-east-1". [Available regions for AWS batch](http://docs.aws.amazon.com/general/latest/gr/rande.html#batch_region)
  can be found in the AWS documentation.
- `timeout::Real`: The maximum number of seconds to wait for workers to become available
  before attempting to proceed without the missing workers.

## Examples
```julia
julia> addprocs(AWSBatchManager(3))  # Needs to be run from within a running AWS batch job
```
"""
AWSBatchManager

struct AWSBatchManager <: ContainerManager
    min_workers::Int
    max_workers::Int
    job_definition::AbstractString
    job_name::AbstractString
    job_queue::AbstractString
    job_memory::Integer
    region::AbstractString
    timeout::Float64

    function AWSBatchManager(
        min_workers::Integer,
        max_workers::Integer,
        definition::AbstractString,
        name::AbstractString,
        queue::AbstractString,
        memory::Integer,
        region::AbstractString,
        timeout::Real=BATCH_TIMEOUT,
    )
        min_workers >= 0 || throw(ArgumentError("min workers must be non-negative"))
        min_workers <= max_workers || throw(ArgumentError("min workers exceeds max workers"))

        # Default the queue to using the WORKER_JOB_QUEUE environmental variable.
        if isempty(queue)
            queue = get(ENV, "WORKER_JOB_QUEUE", "")
        end

        # Workers by default inherit the AWS batch settings from the manager.
        # Note: only query for default values if we need them as the lookup requires special
        # permissions.
        if isempty(definition) || isempty(name) || isempty(queue) || memory == -1
            job = BatchJob()

            if (
                job.definition === nothing || isempty(job.name) || isempty(job.queue)
                || isempty(job.region)
            )
                throw(BatchEnvironmentError(
                    "Unable to perform AWS Batch introspection when not running within " *
                    "an AWS Batch job: $job"
                ))
            end

            definition = isempty(definition) ? job.definition.name : definition
            name = isempty(name) ? job.name : name  # Maybe append "Worker" to default?
            queue = isempty(queue) ? job.queue : queue
            region = isempty(region) ? job.region : region
            memory = memory == -1 ? round(Integer, job.container.memory / job.container.vcpus) : memory
        else
            # At the moment AWS batch only supports the "us-east-1" region
            region = isempty(region) ? "us-east-1" : region
        end

        new(min_workers, max_workers, definition, name, queue, memory, region, timeout)
    end
end

function AWSBatchManager(
    min_workers::Integer,
    max_workers::Integer;
    definition::AbstractString="",
    name::AbstractString="",
    queue::AbstractString="",
    memory::Integer=-1,
    region::AbstractString="",
    timeout::Real=BATCH_TIMEOUT,
)
    AWSBatchManager(
        min_workers,
        max_workers,
        definition,
        name,
        queue,
        memory,
        region,
        timeout
    )
end

function AWSBatchManager{I<:Integer}(workers::UnitRange{I}; kwargs...)
    AWSBatchManager(start(workers), last(workers); kwargs...)
end

function AWSBatchManager(workers::Integer; kwargs...)
    AWSBatchManager(workers, workers; kwargs...)
end

launch_timeout(mgr::AWSBatchManager) = mgr.timeout
desired_workers(mgr::AWSBatchManager) = mgr.min_workers, mgr.max_workers

function get_compute_envs(job_queue::AbstractString)
    queue_desc = get(describe_job_queues(jobQueues = [job_queue]), "jobQueues", nothing)
    if queue_desc === nothing || length(queue_desc) < 1
        throw(BatchEnvironmentError( "Cannot get job queue information for $job_queue."))
    end
    queue_desc = queue_desc[1]
    env_ord = get(queue_desc, "computeEnvironmentOrder", nothing)
    if env_ord === nothing
        throw(BatchEnvironmentError( "Cannot get compute environment information for $job_queue."))
    end
    [get(env, "computeEnvironment", nothing) for env in env_ord]
end

function max_tasks(mgr::AWSBatchManager)
    env_desc = get(describe_compute_environments(computeEnvironments = get_compute_envs(mgr.job_queue)), "computeEnvironments", nothing)
    if env_desc === nothing
        throw(BatchEnvironmentError( "Cannot get compute environment information for $(mgr.job_queue)."))
    end
    total_vcpus = 0
    for env in env_desc
        total_vcpus += get(env["computeResources"], "maxvCpus", 0)
    end
    total_vcpus
end

function ==(a::AWSBatchManager, b::AWSBatchManager)
    return (
        a.min_workers == b.min_workers &&
        a.max_workers == b.max_workers &&
        a.job_definition == b.job_definition &&
        a.job_name == b.job_name &&
        a.job_queue == b.job_queue &&
        a.job_memory == b.job_memory &&
        a.region == b.region &&
        a.timeout == b.timeout
    )
end

function spawn_containers(mgr::AWSBatchManager, override_cmd::Cmd)
    mgr.max_workers < 1 && return nothing
    config = AWSConfig(:creds => AWSCredentials(), :region => mgr.region)

    # Since each batch worker can only use one cpu we override the vcpus to one.
    parameters = [
        "jobName" => mgr.job_name,
        "jobDefinition" => mgr.job_definition,
        "jobQueue" => mgr.job_queue,
        "containerOverrides" => [
            "vcpus" => 1,
            "memory" => mgr.job_memory,
            "command" => override_cmd.exec,
        ],
    ]

    if mgr.max_workers > 1
        # https://docs.aws.amazon.com/batch/latest/userguide/array_jobs.html
        @assert 2 <= mgr.max_workers <= 10_000
        push!(
            parameters,
            "arrayProperties" => [
                "size" => mgr.max_workers,
            ],
        )
    end

    response = @mock submit_job(config, parameters)

    if mgr.max_workers > 1
        notice(logger, "Spawning array job: $(response["jobId"]) (n=$(mgr.max_workers))")
    else
        notice(logger, "Spawning job: $(response["jobId"])")
    end

    return nothing
end

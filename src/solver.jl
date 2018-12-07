include("solver_options.jl")
import Base: copy, length, size

struct Solver{O<:Objective}
    model::Model         # Dynamics model
    obj::O               # Objective (cost function and constraints)
    opts::SolverOptions  # Solver options (iterations, method, convergence criteria, etc)
    dt::Float64          # Time step
    fd::Function         # Discrete in place dynamics function, `fd(_,x,u)`
    Fd::Function         # Jacobian of discrete dynamics, `fx,fu = F(x,u)`
    fc::Function         # Continuous dynamics function (inplace)
    Fc::Function         # Jacobian of continuous dynamics
    c_fun::Function
    c_jacobian::Function
    N::Int64             # Number of time steps
    integration::Symbol
    control_integration::Symbol

    function Solver(model::Model, obj::O; integration::Symbol=:rk4, dt::Float64=NaN, N::Int=-1, opts::SolverOptions=SolverOptions()) where {O}
        # Check for minimum time
        if obj.tf == 0
            minimum_time = true
            dt = 0.
            if N==-1
                throw(ArgumentError("N must be specified for a minimum-time problem"))
            end
        else
            minimum_time = false

            # Handle combination of N and dt
            if isnan(dt) && N>0
                dt = obj.tf / (N-1)
            elseif ~isnan(dt) && N==-1
                N, dt = calc_N(obj.tf, dt)
            elseif isnan(dt) && N==-1
                @warn "Neither dt or N were specified. Setting N = 50"
                N = 50
                dt = obj.tf/N
            elseif ~isnan(dt) && N>0
                if dt !== obj.tf/(N-1)
                    throw(ArgumentError("Specified time step, number of knot points, and final time do not agree ($dt ≢ $(obj.tf)/$(N-1))"))
                end
            end
            if dt == 0
                throw(ArgumentError("dt must be non-zero for non-minimum time problems"))
            end
        end

        # Check N, dt for valid entries
        if N < 0
            err = ArgumentError("$N is not a valid entry for N. Number of knot points must be a positive integer.")
            throw(err)
        elseif dt < 0
            err = ArgumentError("$dt is not a valid entry for dt. Time step must be positive.")
            throw(err)
        end

        if O <: ConstrainedObjective
            opts.constrained = true
        end

        n, m = model.n, model.m
        f! = model.f
        m̄ = m
        if minimum_time
            m̄ += 1
            opts.constrained = true
        end
        opts.minimum_time = minimum_time

        # Get integration scheme
        if isdefined(TrajectoryOptimization,integration)
            discretizer = eval(integration)
        else
            throw(ArgumentError("$integration is not a defined integration scheme"))
        end

        # Determine control integration type
        if integration == :rk3_foh # add more foh options as necessary
            control_integration = :foh
        else
            control_integration = :zoh
        end

        # Generate discrete dynamics equations
        fd! = discretizer(f!, dt)
        f_aug! = f_augmented!(f!, n, m)

        if control_integration == :foh
            """
            s = [x;u;h;v;w]
            x ∈ R^n
            u ∈ R^m
            h ∈ R, h = sqrt(dt_k)
            v ∈ R^m
            w ∈ R, w = sqrt(dt_{k+1})
            -note that infeasible controls are handled in the Jacobian calculation separately
            """
            fd_aug! = fd_augmented_foh!(fd!,n,m)
            nm1 = n + m + 1 + m + 1
        else
            """
            s = [x;u;h]
            x ∈ R^n
            u ∈ R^m
            h ∈ R, h = sqrt(dt_k)
            """
            fd_aug! = discretizer(f_aug!)
            nm1 = n + m + 1
        end

        # Initialize discrete and continuous dynamics Jacobians
        Jd = zeros(nm1, nm1)
        Sd = zeros(nm1)
        Sdotd = zero(Sd)
        Fd!(Jd,Sdotd,Sd) = ForwardDiff.jacobian!(Jd,fd_aug!,Sdotd,Sd)

        Jc = zeros(n+m,n+m)
        Sc = zeros(n+m)
        Scdot = zero(Sc)
        Fc!(Jc,dS,S) = ForwardDiff.jacobian!(Jc,f_aug!,dS,S)

        # Discrete dynamics Jacobians
        if control_integration == :foh
            function fd_jacobians_foh!(x,u,v)
                # Check for infeasible solve
                infeasible = length(u) != m̄

                # Assign state, control (and h = sqrt(dt)) to augmented vector
                Sd[1:n] = x
                Sd[n+1:n+m] = u[1:m]
                minimum_time ? Sd[n+m+1] = u[m̄] : Sd[n+m+1] = √dt
                Sd[n+m+1+1:n+m+1+m] = v[1:m]
                minimum_time ? Sd[n+m+1+m+1] = v[m̄] : Sd[n+m+1+m+1] = √dt

                # Calculate Jacobian
                Fd!(Jd,Sdotd,Sd)

                if infeasible
                    return Jd[1:n,1:n], [Jd[1:n,n+1:n+m̄] I], [Jd[1:n,n+m+1+1:n+m+1+m̄] I] # fx, [fū I], [fv̄ I]
                else
                    return Jd[1:n,1:n], Jd[1:n,n+1:n+m̄], Jd[1:n,n+m+1+1:n+m+1+m̄] # fx, fū, fv̄
                end
            end
            fd_jacobians! = fd_jacobians_foh!
        else
            function fd_jacobians_zoh!(x,u)
                # Check for infeasible solve
                infeasible = length(u) != m̄

                # Assign state, control (and dt) to augmented vector
                Sd[1:n] = x
                Sd[n+1:n+m] = u[1:m]
                minimum_time ? Sd[n+m+1] = u[m̄] : Sd[n+m+1] = √dt

                # Calculate Jacobian
                Fd!(Jd,Sdotd,Sd)

                if infeasible
                    return Jd[1:n,1:n], [Jd[1:n,n.+(1:m̄)] I] # fx, [fū I]
                else
                    return Jd[1:n,1:n], Jd[1:n,n.+(1:m̄)] # fx, fū
                end
            end
            fd_jacobians! = fd_jacobians_zoh!
        end

        function fc_jacobians!(x,u)
            # infeasible = size(u,1) != m̄
            Sc[1:n] = x
            Sc[n+1:n+m] = u[1:m]
            Fc!(Jc,Scdot,Sc)
            return Jc[1:n,1:n], Jc[1:n,n+1:n+m] # fx, fu
        end

        # Generate constraint functions
        c!, c_jacobian! = generate_constraint_functions(obj, max_dt = opts.max_dt, min_dt = opts.min_dt)

        # Copy solver options so any changes don't modify the options passed in
        options = copy(opts)

        new{O}(model, obj, options, dt, fd!, fd_jacobians!, f!, fc_jacobians!, c!, c_jacobian!, N, integration, control_integration)
    end
end

function Solver(solver::Solver; model=solver.model, obj=solver.obj,integration=solver.integration, dt=solver.dt, N=solver.N, opts=solver.opts)
     Solver(model, obj, integration=integration, dt=dt, N=N, opts=opts)
 end

function calc_N(tf::Float64, dt::Float64)::Tuple
    N = convert(Int64,floor(tf/dt)) + 1
    dt = tf/(N-1)
    return N, dt
end

"""
$(SIGNATURES)
Return the quadratic control stage cost R
If using an infeasible start, will return the augmented cost matrix
"""
function getR(solver::Solver)::Array{Float64,2}
    if !solver.opts.infeasible && !is_min_time(solver)
        return solver.obj.R
    else
        n = solver.model.n
        m = solver.model.m
        m̄,mm = get_num_controls(solver)
        R = zeros(mm,mm)
        R[1:m,1:m] = solver.obj.R
        if is_min_time(solver)
            R[m̄,m̄] = solver.opts.R_minimum_time
        end
        if solver.opts.infeasible
            # R[m̄+1:end,m̄+1:end] = Diagonal(ones(n)*solver.opts.R_infeasible*tr(solver.obj.R))
            R[m̄+1:end,m̄+1:end] = Diagonal(ones(n)*solver.opts.R_infeasible)
        end
        return R
    end
end # TODO: make this type stable (maybe make it a type so it only calculates once)

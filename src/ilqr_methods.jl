"""
$(SIGNATURES)
Get number of (solver) controls, accounting for minimum time and infeasible start
# Output
- m̄:  number of non infeasible controls (ie, system controls + time control if minimum time). System controls augmented by one if time is included as a control for minimum time problems.
- mm: total number of solver controls
"""
function get_num_controls(solver::Solver)
    n,m = get_sizes(solver)
    m̄ = m
    solver.state.minimum_time ? m̄ += 1 : nothing
    solver.state.infeasible ? mm = m̄ + n : mm = m̄
    return m̄, mm
end

"""
$(SIGNATURES)
    Compute the optimal control problem cost
"""
function cost(solver::Solver,vars::DircolVars)
    cost(solver,vars.X,vars.U)
end

function cost(solver::Solver, X::AbstractMatrix, U::AbstractMatrix)
    cost(solver, to_dvecs(X), to_dvecs(U))
end

function cost(solver::Solver,X::AbstractVector,U::AbstractVector)
    N = solver.N
    J = 0.0
    costfun = solver.obj.cost
    for k = 1:N-1
        J += stage_cost(costfun,X[k],U[k])*solver.dt
    end
    J += stage_cost(costfun, X[N])
end

"""
$(SIGNATURES)
    Compute the optimal control problem unconstrained cost,
    including minimum time and infeasible controls
"""
function _cost(solver::Solver{Obj},res::SolverVectorResults,X=res.X,U=res.U) where Obj <: Union{ConstrainedObjective, UnconstrainedObjective}
    # pull out solver/objective values
    n,m,N = get_sizes(solver)
    m̄,mm = get_num_controls(solver)
    costfun = solver.obj.cost
    dt = solver.dt
    xf = solver.obj.xf

    J = 0.0
    for k = 1:N-1
        # Get dt if minimum time
        solver.state.minimum_time ? dt = U[k][m̄]^2 : nothing

        # Stage cost
        J += (stage_cost(costfun,X[k],U[k][1:m]))*dt

        # Minimum time cost
        solver.state.minimum_time ? J += solver.opts.R_minimum_time*dt : nothing

        # Infeasible control cost
        solver.state.infeasible ? J += 0.5*solver.opts.R_infeasible*U[k][m̄.+(1:n)]'*U[k][m̄.+(1:n)] : nothing
    end

    # Terminal Cost
    J += stage_cost(costfun, X[N])

    return J
end

"""
$(SIGNATURES)
    Compute the Augmented Lagrangian constraints cost
"""
function cost_constraints(solver::Solver, res::ConstrainedIterResults)
    N = solver.N
    J = 0.0
    for k = 1:N
        J += 0.5*res.C[k]'*res.Iμ[k]*res.C[k] + res.λ[k]'*res.C[k]
    end

    return J
end

function cost_constraints(solver::Solver, res::UnconstrainedIterResults)
    return 0.
end

function cost(solver::Solver, res::SolverIterResults, X=res.X, U=res.U)
    _cost(solver,res,X,U) + cost_constraints(solver,res)
end

"""
$(SIGNATURES)
    Calculate dynamics and constraint Jacobians (perform prior to the backwards pass)
"""
function calculate_jacobians!(res::ConstrainedIterResults, solver::Solver)::Nothing
    n,m,N = get_sizes(solver)
    m̄,mm = get_num_controls(solver)
    dt = solver.dt

    for k = 1:N-1
        # Update discrete dynamics Jacobians
        res.fdx[k], res.fdu[k] = solver.Fd(res.X[k], res.U[k])

        # Update constraint Jacobians
        solver.c_jacobian(res.Cx[k], res.Cu[k], res.X[k],res.U[k])

        # Minimum time special case
        if solver.state.minimum_time && k < N-1
            res.Cu[k][end,m̄] = 1
        end
    end

    # Update terminal constraint Jacobian
    k = N
    solver.c_jacobian(res.Cx[k], res.X[k])

    return nothing
end

function calculate_jacobians!(res::UnconstrainedIterResults, solver::Solver)::Nothing
    n,m,N = get_sizes(solver)
    m̄,mm = get_num_controls(solver)

    for k = 1:N-1
        # Update discrete dynamics Jacobians
        res.fdx[k], res.fdu[k] = solver.Fd(res.X[k], res.U[k])
    end

    return nothing
end

function evaluate_trajectory(solver::Solver, X, U)
    n,m,N = get_sizes(solver)
    m̄,mm = get_num_controls(solver)
    p,pI,pE = get_num_constraints(solver)
    results = init_results(solver,X,U)
    calculate_midpoints!(results, solver)
    calculate_derivatives!(results, solver)
    calculate_jacobians!(results, solver)
    update_constraints!(results, solver)
    return results
end

"""
$(SIGNATURES)
Interpolate a trajectory using cubic interpolation
"""
function interp_traj(N::Int,tf::Float64,X::Matrix,U::Matrix)::Tuple{Matrix,Matrix}
    if isempty(X)
        X2 = X
    else
        X2 = interp_rows(N,tf,X)
    end
    U2 = interp_rows(N-1,tf,U)
    return X2, U2
end

"""
$(SIGNATURES)
Interpolate the rows of a matrix using cubic interpolation
"""
function interp_rows(N::Int,tf::Float64,X::Matrix)::Matrix
    n,N1 = size(X)
    t1 = range(0,stop=tf,length=N1)
    t2 = collect(range(0,stop=tf,length=N))
    X2 = zeros(n,N)
    for i = 1:n
        interp_cubic = CubicSplineInterpolation(t1, X[i,:])
        X2[i,:] = interp_cubic(t2)
    end
    return X2
end

"""
$(SIGNATURES)
Generates the correctly sized input trajectory, tacking on infeasible and minimum
time controls, if required. Will interpolate the initial trajectory as needed.
# Arguments
* X0: Matrix of initial states. May be empty. If empty and the infeasible flag is set in the solver, it will initialize a linear interpolation from start to goal state.
* U0: Matrix of initial controls. May either be only the dynamics controls, or include infeasible and minimum time controls (as necessary).
"""
function get_initial_trajectory(solver::Solver, X0::Matrix{Float64}, U0::Matrix{Float64})
    n,m,N = get_sizes(solver)
    m̄,mm = get_num_controls(solver)
    if size(U0,1) ∉ [m,mm]
        ArgumentError("Size of U0 must be either include only plant controls or all expected controls (infeasible + minimum time)")
    end

    if N != size(U0,2)
        @info "Interpolating initial guess"
        X0,U0 = interp_traj(N,solver.obj.tf,X0,U0)
    end

    if solver.state.minimum_time
        solver.state.infeasible ? sep = " and " : sep = " with "
        solve_string = sep * "minimum time..."

        # Initialize controls with sqrt(dt)
        if size(U0,1) == m
            U_init = [U0; ones(1,size(U0,2))*sqrt(get_initial_dt(solver))]
        end
    else
        solve_string = "..."
        U_init = U0
    end

    if solver.state.infeasible
        solve_string =  "Solving Constrained Problem with Infeasible Start" * solve_string

        # Generate infeasible controls
        if size(U0,1) == m
            ui = infeasible_controls(solver,X0,U_init)  # generates n additional control input sequences that produce the desired infeasible state trajectory
            U_init = [U_init; ui]  # augment control with additional control inputs that produce infeasible state trajectory
        end

        # Assign state trajectory
        if isempty(X0)
            X_init = line_trajectory(solver)
        else
            X_init = X0
        end
    else
        if solver.state.constrained
            solve_string = "Solving Constrained Problem" * solve_string
        else
            solve_string = "Solving Unconstrained Problem" * solve_string
        end
        X_init = zeros(n,N)
    end
    @info solve_string

    return X_init, U_init
end

"""
$(SIGNATURES)
    Regularization update scheme
        - see "Synthesis and Stabilization of Complex Behaviors through Online Trajectory Optimization"
"""
function regularization_update!(results::SolverResults,solver::Solver,status::Symbol=:increase)
    if status == :increase # increase regularization
        # @logmsg InnerLoop "Regularization Increased"
        results.dρ[1] = max(results.dρ[1]*solver.opts.ρ_factor, solver.opts.ρ_factor)
        results.ρ[1] = max(results.ρ[1]*results.dρ[1], solver.opts.ρ_min)
        if results.ρ[1] > solver.opts.ρ_max
            @warn "Max regularization exceeded"
        end
    elseif status == :decrease # decrease regularization
        results.dρ[1] = min(results.dρ[1]/solver.opts.ρ_factor, 1.0/solver.opts.ρ_factor)
        results.ρ[1] = results.ρ[1]*results.dρ[1]*(results.ρ[1]*results.dρ[1]>solver.opts.ρ_min)
    end
end

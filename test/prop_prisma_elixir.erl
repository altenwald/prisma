-module(prop_prisma_elixir).

-include_lib("proper/include/proper.hrl").
-include("prisma.hrl").

-export([
    prop_elixir_inference_and_checks_agree_with_execution/0
]).

%%--------------------------------------------------------------------
%% Property: Elixir-compiled BEAMs match execution and catch mismatches
%%--------------------------------------------------------------------

prop_elixir_inference_and_checks_agree_with_execution() ->
    case ensure_elixir() of
        false ->
            true;
        true ->
            ?FORALL(Spec, gen_elixir_program(),
                begin
                    {Mod, HelperMod, Source} = build_elixir_source(Spec),
                    Compiled = compile_elixir(Source),
                    try
                        Beams = [Bin || {_M, Bin} <- Compiled],
                        {ok, Warnings} = prisma:analyze_beams(Beams, #{mode => hybrid, oxbow => false}),
                        Summaries = [begin {ok, S} = prisma_abstract:extract_beam(B), S end || B <- Beams],
                        NoPhantom = check_no_phantom_calls(Mod, Summaries),
                        ExecOk = check_execution_and_specs(Mod, Spec, Warnings, Summaries),
                        NoPhantom andalso ExecOk
                    after
                        cleanup_module(Mod),
                        cleanup_module(HelperMod)
                    end
                end)
    end.

%%--------------------------------------------------------------------
%% Generators
%%--------------------------------------------------------------------

gen_elixir_program() ->
    {
        elements([case_expr, cond_expr, with_expr, for_expr, try_after_expr,
                  receive_expr, bitstring_size_expr, zero_arg_remote_expr,
                  struct_vs_map_expr]),
        oneof([int_val, bin_val, atom_val]),
        boolean()
    }.

build_elixir_source({Kind, RetKind, BadSpec}) ->
    Id = integer_to_list(erlang:unique_integer([positive])),
    HelperMod = list_to_atom("Elixir.PropExHelper" ++ Id),
    Mod = list_to_atom("Elixir.PropExMod" ++ Id),
    HelperStr = atom_name(HelperMod),
    ModStr = atom_name(Mod),
    {ExpectedSpec, RuntimeVal, WrongSpec} = case RetKind of
        int_val -> {"integer()", "42", "atom()"};
        bin_val -> {"String.t()", "\"ok\"", "integer()"};
        atom_val -> {"atom()", ":good", "integer()"}
    end,
    UsedSpec = case BadSpec of
        true -> WrongSpec;
        false -> ExpectedSpec
    end,
    Body = case Kind of
        case_expr ->
            "    case Helper.val() do\n"
            "      :ok -> " ++ RuntimeVal ++ "\n"
            "      _ -> " ++ RuntimeVal ++ "\n"
            "    end\n";
        cond_expr ->
            "    cond do\n"
            "      Helper.val() == :ok -> " ++ RuntimeVal ++ "\n"
            "      true -> " ++ RuntimeVal ++ "\n"
            "    end\n";
        with_expr ->
            "    with :ok <- Helper.val() do\n"
            "      " ++ RuntimeVal ++ "\n"
            "    else\n"
            "      _ -> " ++ RuntimeVal ++ "\n"
            "    end\n";
        for_expr ->
            "    for _x <- [1], do: " ++ RuntimeVal ++ "\n";
        try_after_expr ->
            "    try do\n"
            "      " ++ RuntimeVal ++ "\n"
            "    after\n"
            "      :cleanup\n"
            "    end\n";
        receive_expr ->
            "    receive do\n"
            "      :never -> " ++ RuntimeVal ++ "\n"
            "    after\n"
            "      0 -> " ++ RuntimeVal ++ "\n"
            "    end\n";
        bitstring_size_expr ->
            "    _bits = <<7::size(Helper.width())>>\n"
            "    " ++ RuntimeVal ++ "\n";
        zero_arg_remote_expr ->
            "    _ = Helper.val()\n"
            "    m = %{k: " ++ RuntimeVal ++ "}\n"
            "    m.k\n";
        struct_vs_map_expr ->
            "    pick(%{k: " ++ RuntimeVal ++ "})\n"
    end,
    FinalSpec = case Kind of
        for_expr ->
            case BadSpec of
                true -> "atom()";
                false -> "[" ++ ExpectedSpec ++ "]"
            end;
        _ ->
            UsedSpec
    end,
    ExtraFns = case Kind of
        struct_vs_map_expr ->
            "  defstruct [:entry]\n"
            "  @type t :: %__MODULE__{entry: term()}\n"
            "  @spec pick(t() | map() | list()) :: " ++ ExpectedSpec ++ "\n"
            "  def pick(%__MODULE__{}), do: " ++ RuntimeVal ++ "\n"
            "  def pick(%{k: _}), do: " ++ RuntimeVal ++ "\n"
            "  def pick(v) when is_map(v), do: " ++ RuntimeVal ++ "\n"
            "  def pick(v) when is_list(v), do: " ++ RuntimeVal ++ "\n";
        _ ->
            ""
    end,
    Source = lists:flatten([
        "defmodule ", HelperStr, " do\n",
        "  @spec val() :: :ok | :error\n",
        "  def val() do\n",
        "    if :erlang.phash2(self()) == -1, do: :error, else: :ok\n",
        "  end\n",
        "  @spec width() :: pos_integer()\n",
        "  def width(), do: 8\n",
        "end\n\n",
        "defmodule ", ModStr, " do\n",
        "  alias ", HelperStr, ", as: Helper, warn: false\n",
        ExtraFns,
        "  @spec run() :: ", FinalSpec, "\n",
        "  def run() do\n",
        Body,
        "  end\n",
        "end\n"
    ]),
    {Mod, HelperMod, unicode:characters_to_binary(Source)}.

atom_name(Atom) ->
    "Elixir." ++ Rest = atom_to_list(Atom),
    Rest.

%%--------------------------------------------------------------------
%% Checks
%%--------------------------------------------------------------------

check_no_phantom_calls(Mod, Summaries) ->
    PhantomNames = ['try', 'receive', 'for', 'with', 'cond'],
    lists:all(
        fun(#module_summary{functions = Funcs}) ->
            lists:all(
                fun({_MFA, #func_contract{calls = Calls}}) ->
                    not lists:any(
                        fun({M, F, _A}) ->
                            (M =:= Mod andalso lists:member(F, PhantomNames))
                            orelse {M, F} =:= {erlang, size}
                        end,
                        Calls
                    )
                end,
                maps:to_list(Funcs)
            )
        end,
        Summaries
    ).

check_execution_and_specs(Mod, {Kind, _RetKind, BadSpec}, Warnings, Summaries) ->
    Result = Mod:run(),
    [Summary] = [S || #module_summary{module = M} = S <- Summaries, M =:= Mod],
    FC = maps:get({Mod, run, 0}, Summary#module_summary.functions),
    {fun_type, [], InferredRet} = FC#func_contract.inferred_type,
    MemberOk = prisma_oracle:member(Result, InferredRet),
    NoDiscrepancyOrDead = not lists:any(
        fun(#prisma_warning{kind = K}) -> K =:= discrepancy orelse K =:= dead_code end,
        Warnings
    ),
    HasGradual = lists:any(
        fun(#prisma_warning{kind = K, mfa = {M, run, 0}}) -> K =:= gradual_mismatch andalso M =:= Mod;
           (#prisma_warning{kind = K, mfa = {M, pick, 1}}) -> K =:= gradual_mismatch andalso M =:= Mod andalso Kind =:= struct_vs_map_expr;
           (_) -> false
        end,
        Warnings
    ),
    SpecOk = case BadSpec of
        true -> HasGradual;
        false -> not HasGradual
    end,
    MemberOk andalso NoDiscrepancyOrDead andalso SpecOk.

%%--------------------------------------------------------------------
%% Elixir runtime helpers
%%--------------------------------------------------------------------

ensure_elixir() ->
    case code:which('Elixir.Code') of
        non_existing ->
            case os:find_executable("elixir") of
                false ->
                    false;
                ElixirBin ->
                    Out = string:trim(os:cmd(ElixirBin ++ " -e \"IO.puts(:code.lib_dir(:elixir))\"")),
                    Ebin = filename:join(Out, "ebin"),
                    case filelib:is_dir(Ebin) of
                        true ->
                            true = code:add_patha(Ebin),
                            {ok, _} = application:ensure_all_started(elixir),
                            true;
                        false ->
                            false
                    end
            end;
        _ ->
            {ok, _} = application:ensure_all_started(elixir),
            true
    end.

compile_elixir(Source) ->
    'Elixir.Code':compile_string(Source).

cleanup_module(Mod) ->
    _ = code:purge(Mod),
    _ = code:delete(Mod),
    _ = code:purge(Mod),
    ok.

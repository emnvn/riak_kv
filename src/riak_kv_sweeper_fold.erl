%% -------------------------------------------------------------------
%%
%% riak_kv_sweeper_fold: Riak sweep scheduler callbacks
%%
%% Copyright (c) 2016 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(riak_kv_sweeper_fold).

-include("riak_kv_sweeper.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([do_sweep/8]).
-export([get_sweep_throttle/0]).
-export([send_to_sweep_worker/2]).

-define(MAX_SWEEP_CRASHES, 10).
%% Throttle used when sweeping over K/V data: {Type, Limit, Wait}.
%% Type can be pace or obj_size.
%% Default: 1 MB limit / 100 ms wait
-define(DEFAULT_SWEEP_THROTTLE, {obj_size, 1000000, 100}).

%% Default value for how much faster the sweeper throttle should be during
%% sweep window.
-define(SWEEP_WINDOW_THROTTLE_DIV, 1).

-type opaque() :: any(). % Anything marked opaque should not be inspected

-type sweep_result() :: {SweptKeys :: non_neg_integer(),
                         [{riak_kv_sweeper:participant_module(), 'succ' | 'fail'}]}.

-export_type([sweep_result/0]).

-spec do_sweep([ActiveParticipants :: #sweep_participant{}],
               EstimatedKeys       :: non_neg_integer(),
               Sender              :: opaque(),
               Opts                :: [],
               Index               :: riak_kv_sweeper:index(),
               Mod                 :: atom(),
               ModState            :: opaque(),
               VnodeState          :: opaque()) ->

    {reply, Acc :: #sa{}, VnodeState :: opaque()}
  | {reply, Reason :: opaque(), VnodeState :: opaque()}
  | {async, {sweep, Work :: opaque(), FinishFun :: fun((#sa{}) -> #sa{})}, Sender :: opaque(), VnodeState :: opaque()}.

do_sweep(ActiveParticipants, EstimatedKeys, Sender, Opts, Index, Mod, ModState, VnodeState) ->
    InitialAcc = make_initial_acc(Index, ActiveParticipants, EstimatedKeys),
    case Mod:fold_objects(fun fold_req_fun/4, InitialAcc, Opts, ModState) of
        {ok, #sa{} = Acc} ->
            inform_participants(Acc, Index),
            riak_kv_sweeper:sweep_result(Index, format_result(Acc)),
            Acc1 = stat_send(Index, Acc),
            {reply, Acc1, VnodeState};
        {async, Work} ->
            FinishFun =
                fun(Acc) ->
                        inform_participants(Acc, Index),
                        riak_kv_sweeper:sweep_result(Index, format_result(Acc)),
                        stat_send(Index, Acc)
                end,
            {async, {sweep, Work, FinishFun}, Sender, VnodeState};
        Reason ->
            failed_sweep(ActiveParticipants, Index, Reason),
            {reply, Reason, VnodeState}
    end.


-spec fold_req_fun(riak_object:bucket(), riak_object:key(), RObjBin :: binary(), #sa{}) ->
   #sa{} | no_return().
fold_req_fun(_Bucket, _Key, _RObjBin,
             #sa{active_p = [], failed_p = Failed} = Acc) when Failed =/= [] ->
    lager:error("No more participants in sweep of Index ~p Failed: ~p", [Acc#sa.index, Failed]),
    throw({stop_sweep, Acc});

fold_req_fun(Bucket, Key, RObjBin, #sa{index = Index, swept_keys = SweptKeys} = Acc) ->
    Acc1 = maybe_throttle_sweep(RObjBin, Acc),
    Acc3 =
        case SweptKeys rem 1000 of
            0 ->
                riak_kv_sweeper:update_progress(Index, SweptKeys),
                Acc2 = maybe_receive_request(Acc1),
                stat_send(Index, Acc2);
            _ ->
                Acc1
        end,
    RObj = riak_object:from_binary(Bucket, Key, RObjBin),
    Acc4 = update_stat_counters(byte_size(RObjBin), Acc3),
    apply_sweep_participant_funs({{Bucket, Key}, RObj}, Acc4#sa{swept_keys = SweptKeys + 1}).

-spec make_initial_acc(riak_kv_sweeper:index(), [#sweep_participant{}], EstimatedKeys :: non_neg_integer()) -> #sa{}.
make_initial_acc(Index, ActiveParticipants, EstimatedNrKeys) ->
    SweepsParticipants = sort_participants(ActiveParticipants),
    #sa{index = Index, active_p = SweepsParticipants, estimated_keys = EstimatedNrKeys}.

-spec sort_participants([#sweep_participant{}]) -> [#sweep_participant{}].
sort_participants(Participants) ->
    lists:sort(fun compare_participants/2, Participants).

-spec compare_participants(#sweep_participant{}, #sweep_participant{}) -> boolean().
compare_participants(A, B) ->
    TypeA = A#sweep_participant.fun_type,
    TypeB = B#sweep_participant.fun_type,
    fun_type_rank(TypeA) =< fun_type_rank(TypeB).

-spec fun_type_rank('delete_fun'|'modify_fun'|'observe_fun') -> 1| 2| 3.
fun_type_rank(delete_fun) -> 1;
fun_type_rank(modify_fun) -> 2;
fun_type_rank(observe_fun) -> 3.

-spec inform_participants(#sa{}, riak_kv_sweeper:index()) -> [].
inform_participants(#sa{active_p = Succ, failed_p = Failed}, Index) ->
    successful_sweep(Succ, Index),
    failed_sweep(Failed, Index).

-spec successful_sweep([#sweep_participant{}], riak_kv_sweeper:index()) -> [].
successful_sweep(Succ, Index) ->
    [Module:successful_sweep(Index, FinalAcc) ||
       #sweep_participant{module = Module, acc = FinalAcc} <- Succ].

-spec failed_sweep([#sweep_participant{}], riak_kv_sweeper:index()) -> [].
failed_sweep(Failed, Index) ->
    [Module:failed_sweep(Index, Reason) ||
       #sweep_participant{module = Module, fail_reason = Reason } <- Failed].

failed_sweep(Failed, Index, Reason) ->
    [Module:failed_sweep(Index, Reason) ||
       #sweep_participant{module = Module} <- Failed].

-spec format_result(#sa{}) -> sweep_result().
format_result(#sa{swept_keys = SweptKeys, active_p = Succ, failed_p = Failed}) ->
    {SweptKeys,
     format_result(succ, Succ) ++ format_result(fail, Failed)}.

-spec format_result('succ'|'fail', [#sweep_participant{}]) -> [{riak_kv_sweeper:participant_module(), 'succ' | 'fail'}].
format_result(SuccFail, Results) ->
    [{Module, SuccFail} || #sweep_participant{module = Module} <- Results].

%% Throttle depending on swept keys.
-spec maybe_throttle_sweep(binary(), #sa{} ) -> #sa{}.
maybe_throttle_sweep(_RObjBin, #sa{throttle = {pace, Limit, Wait},
                         swept_keys = SweepKeys,
                         throttle_total_wait_msecs = ThrottleTotalWait} = SweepAcc) ->
    case SweepKeys rem Limit of
        0 ->
            NewThrottle = get_sweep_throttle(),
            %% We use receive after to throttle instead of sleep.
            %% This way we can respond on requests while throttling
            SweepAcc0 = SweepAcc#sa{throttle = NewThrottle,
                                    throttle_total_wait_msecs = ThrottleTotalWait + Wait},
            timer:sleep(Wait),
            maybe_extra_throttle(SweepAcc0);
        _ ->
            maybe_extra_throttle(SweepAcc)
    end;

%% Throttle depending on total obj_size.
maybe_throttle_sweep(RObjBin, #sa{throttle = {obj_size, Limit, Wait},
                         total_obj_size = TotalObjSize,
                         throttle_total_wait_msecs = ThrottleTotalWait} = SweepAcc) ->
    ObjSize = byte_size(RObjBin),
    TotalObjSize1 = ObjSize + TotalObjSize,
    case (Limit =/= 0) andalso (TotalObjSize1 > Limit) of
        true ->
            NewThrottle = get_sweep_throttle(),
            %% We use receive after to throttle instead of sleep.
            %% This way we can respond on requests while throttling
            SweepAcc0 = SweepAcc#sa{throttle = NewThrottle,
                                    throttle_total_wait_msecs = ThrottleTotalWait + Wait},
            timer:sleep(Wait),
            maybe_extra_throttle(SweepAcc0#sa{total_obj_size = 0});
        _ ->
            maybe_extra_throttle(SweepAcc#sa{total_obj_size = TotalObjSize1})
    end.

%% Throttle depending on how many objects the sweep modify.
-spec maybe_extra_throttle(#sa{}) -> #sa{}.
maybe_extra_throttle(#sa{throttle = Throttle,
                         throttle_total_wait_msecs = ThrottleTotalWait,
                         modified_objects = ModObj} = SweepAcc) ->
    {Limit, Wait} =
        case Throttle of
            {pace, Limit0, Wait0} ->
                {Limit0, Wait0};
            {obj_size, _Limit0, Wait0} ->
                {100, Wait0}
        end,
    %% +1 since some sweeps doesn't modify any objects
    case (ModObj + 1) rem Limit of
        0 ->
            timer:sleep(Wait),
            SweepAcc#sa{throttle_total_wait_msecs = ThrottleTotalWait + Wait};
        _ ->
            SweepAcc
    end.

%% Throttle depending on how many objects the sweep modify.
-spec get_sweep_throttle() -> {'obj_size'|'pace', Limit :: non_neg_integer(), Sleep :: non_neg_integer()}.
get_sweep_throttle() ->
    {Type, Limit, Sleep} =
        app_helper:get_env(riak_kv, sweep_throttle, ?DEFAULT_SWEEP_THROTTLE),
    case riak_kv_sweeper:in_sweep_window() of
        true ->
            Div = app_helper:get_env(riak_kv, sweep_window_throttle_div,
                                     ?SWEEP_WINDOW_THROTTLE_DIV),
            {Type, Limit, Sleep div Div};
        false ->
            {Type, Limit, Sleep}
    end.

-spec send_to_sweep_worker(Msg :: stop|{disable, Module:: atom()}, #sweep{}) -> ok|no_pid.
send_to_sweep_worker(Msg, #sweep{pid = Pid}) when is_pid(Pid) ->
    lager:debug("Send to sweep worker ~p: ~p", [Pid, Msg]),
    Pid ! Msg;

send_to_sweep_worker(Msg, #sweep{index = Index}) ->
    lager:info("no pid ~p to ~p " , [Msg, Index]),
    no_pid.

-spec maybe_receive_request(#sa{}) -> #sa{}.
maybe_receive_request(#sa{active_p = Active, failed_p = Fail } = Acc) ->
    receive
        stop ->
            Active1 =
                [ActiveSP#sweep_participant{fail_reason = sweep_stop } ||
                 #sweep_participant{} = ActiveSP <- Active],
            Acc#sa{active_p = [],  failed_p = Active1 ++ Fail};
        {disable, Module} ->
            case lists:keytake(Module, #sweep_participant.module, Active) of
                {value, SP, Active1} ->
                    Acc#sa{active_p = Active1,
                           failed_p = [SP#sweep_participant{fail_reason = disable} | Fail]};
                _ ->
                    Acc
            end
    after 0 ->
        Acc
    end.

-spec apply_sweep_participant_funs({{riak_object:bucket(), riak_object:key()}, riak_object:riak_object()}, #sa{}) -> #sa{}.
apply_sweep_participant_funs({BKey, RObj}, SweepAcc) ->
    ActiveParticipants = SweepAcc#sa.active_p,
    FailedParticipants = SweepAcc#sa.failed_p,
    Index = SweepAcc#sa.index,
    BucketProps = SweepAcc#sa.bucket_props,

    InitialAcc = {RObj,
                  FailedParticipants,
                  _Successful = [],
                  _ModifiedObjs = 0,
                  BucketProps},
    FoldFun = fun(E, Acc) -> run_participant_fun(E, Index, BKey, Acc) end,
    Results = lists:foldl(FoldFun, InitialAcc, ActiveParticipants),

    {_, Failed, Successful, ModifiedObjs, NewBucketProps} = Results,

    SweepAcc1 = update_modified_objs_count(SweepAcc, ModifiedObjs),
    SweepAcc2 = SweepAcc1#sa{bucket_props = NewBucketProps},
    update_sa_with_participant_results(SweepAcc2, Failed, Successful).

%% Check if the sweep_participant have reached crash limit.
-spec run_participant_fun(
        #sweep_participant{},
        riak_kv_sweeper:index(),
        {riak_object:bucket(), riak_object:key()},
        {riak_object:riak_object(), [#sweep_participant{}], [#sweep_participant{}], ModifiedObjs :: non_neg_integer(), BucketProps :: []}) ->
   {riak_object:riak_object(), [#sweep_participant{}], [#sweep_participant{}], ModifiedObjs :: non_neg_integer(), BucketProps :: []}.
run_participant_fun(SP = #sweep_participant{errors = ?MAX_SWEEP_CRASHES, module = Module},
                    _Index, _BKey, {RObj, Failed, Successful, ModifiedObjs, BucketProps}) ->
    lager:error("Sweeper fun ~p crashed too many times.", [Module]),
    FailedSP = SP#sweep_participant{fail_reason = too_many_crashes},
    {RObj, [FailedSP | Failed], Successful, ModifiedObjs, BucketProps};

run_participant_fun(SP, _Index, _BKey,
                    {deleted, Failed, Successful, ModifiedObjs, BucketProps}) ->
    {deleted, Failed, [SP | Successful], ModifiedObjs, BucketProps};

run_participant_fun(SP, Index, BKey,
                    {RObj, Failed, Successful, ModifiedObjs, BucketProps}) ->
    Fun = SP#sweep_participant.sweep_fun,
    ParticipantAcc = SP#sweep_participant.acc,
    Errors = SP#sweep_participant.errors,
    Options = SP#sweep_participant.options,

    {Bucket, _Key} = BKey,
    {OptValues, NewBucketProps} = maybe_add_bucket_info(Bucket, BucketProps, Options),

    try Fun({BKey, RObj}, ParticipantAcc, OptValues) of
        Result ->
            {NewRObj, NumModified, NewParticipantAcc} = do_participant_side_effects(
                                                          Result, Index, BKey, RObj),
            NewSucc = [SP#sweep_participant{acc = NewParticipantAcc} | Successful],
            {NewRObj, Failed, NewSucc, ModifiedObjs + NumModified, NewBucketProps}
    catch C:T ->
              lager:error("Sweeper fun crashed ~p ~p Key: ~p Obj: ~p", [{C, T}, SP, BKey, RObj]),
              %% We keep the sweep in succ unil we have enough crashes
              NewSucc = [SP#sweep_participant{errors = Errors + 1} | Successful],
              {RObj, Failed, NewSucc, ModifiedObjs, NewBucketProps}
    end.

-spec do_participant_side_effects({deleted, #sa{}},                            riak_kv_sweeper:index(), {riak_object:bucket(), riak_object:key()}, riak_object:riak_object()) -> {deleted, 1, #sa{}};
                                 ({mutated, riak_object:riak_object(), #sa{}}, riak_kv_sweeper:index(), {riak_object:bucket(), riak_object:key()}, riak_object:riak_object()) -> {riak_object:riak_object(), 1, #sa{}};
                                 ({ok, #sa{}},                                 riak_kv_sweeper:index(), {riak_object:bucket(), riak_object:key()}, riak_object:riak_object()) -> {riak_object:riak_object(), 0, #sa{}}.
do_participant_side_effects({deleted, NewAcc}, Index, BKey, RObj) ->
    riak_kv_vnode:local_reap(Index, BKey, RObj),
    {deleted, 1, NewAcc};
do_participant_side_effects({mutated, MutatedRObj, NewAcc}, Index, _BKey, _RObj) ->
    riak_kv_vnode:local_put(Index, MutatedRObj, [{hashtree_action, tombstone}]),
    {MutatedRObj, 1, NewAcc};
do_participant_side_effects({ok, NewAcc}, _Index, _BKey, RObj) ->
    {RObj, 0, NewAcc}.

-spec update_modified_objs_count(#sa{}, ModifiedObjs :: non_neg_integer()) -> #sa{}.
update_modified_objs_count(SweepAcc, ModifiedObjs) ->
    PreviouslyModObjs = SweepAcc#sa.modified_objects,
    SweepAcc#sa{modified_objects = PreviouslyModObjs + ModifiedObjs}.

-spec update_sa_with_participant_results(#sa{}, [#sweep_participant{}], [#sweep_participant{}]) -> #sa{}.
update_sa_with_participant_results(SweepAcc, Failed, Successful) ->
    SweepAcc#sa{active_p = lists:reverse(Successful),
                failed_p = Failed,
                succ_p = []}.

-spec maybe_add_bucket_info(riak_object:bucket(), BucketProps :: dict(), Options :: [term()]) -> {[term()], BucketProps :: dict()}.
maybe_add_bucket_info(Bucket, BucketPropsDict, Options) ->
    case lists:member(bucket_props, Options) of
        true ->
            {BucketProps, BucketPropsDict1} = get_bucket_props(Bucket, BucketPropsDict),
            {[{bucket_props, BucketProps}], BucketPropsDict1};
        false ->
            {[], BucketPropsDict}
    end.

-spec get_bucket_props(riak_object:bucket(), BucketProps :: dict()) -> {BucketProps :: [], BucketPropsDict :: dict()}.
get_bucket_props(Bucket, BucketPropsDict) ->
    case dict:find(Bucket, BucketPropsDict) of
        {ok, BucketProps} ->
            {BucketProps, BucketPropsDict};
        _ ->
            BucketProps = riak_core_bucket:get_bucket(Bucket),
            BucketPropsDict1 = dict:store(Bucket, BucketProps, BucketPropsDict),
            {BucketProps, BucketPropsDict1}
    end.

-spec update_stat_counters(BinSize :: non_neg_integer(), #sa{}) -> #sa{}.
update_stat_counters(RObjBinSize, Acc) ->
    StatSweptKeysCounter = Acc#sa.stat_swept_keys_counter,
    StatObjSizeCounter = Acc#sa.stat_obj_size_counter,

    Acc#sa{stat_obj_size_counter = StatObjSizeCounter + RObjBinSize,
           stat_swept_keys_counter = StatSweptKeysCounter + 1}.

-spec stat_send(riak_kv_sweeper:index(), #sa{}) -> #sa{}.
stat_send(Index, Acc) ->
    riak_kv_stat:update({sweeper, Index, keys, Acc#sa.stat_swept_keys_counter}),
    riak_kv_stat:update({sweeper, Index, bytes, Acc#sa.stat_obj_size_counter}),
    Acc#sa{stat_swept_keys_counter = 0,
           stat_obj_size_counter = 0}.

-ifdef(TEST).

setup_sweep(N) ->
    meck:new(riak_kv_vnode, []),
    meck:expect(riak_kv_vnode, local_put, fun(_, _, _) -> [] end),
    meck:expect(riak_kv_vnode, local_reap, fun(_, _, _) -> [] end),
    meck:new(riak_core_bucket),
    meck:expect(riak_core_bucket, get_bucket, fun(_) -> [] end),
    [meck_callback_modules(Module) ||
       Module <- [delete_callback_module, modify_callback_module, observ_callback_module]],
    meck:new(fake_backend, [non_strict]),
    Keys = make_keys(N),
    BackendFun =
        fun(CompleteFoldReq, InitialAcc, _, _) ->
                SA = lists:foldl(fun(NBin, Acc) ->
                                         InitialObj = riak_object:new(NBin, NBin, <<>>),
                                         ObjBin = riak_object:to_binary(v1, InitialObj),
                                         CompleteFoldReq(NBin, NBin, ObjBin, Acc)
                                 end, InitialAcc, Keys),
                {ok, SA}
        end,
    meck:expect(fake_backend, fold_objects, BackendFun).

observ_sweep() ->
    %% Keep track on nr of modified and original objects
    ObservFun = fun({{_, _BKey}, <<"mutated">>}, {Mut, Org}, _Opt) -> {ok, {Mut + 1, Org}};
                   ({{_, _BKey}, _RObj}, {Mut, Org}, _Opt) -> {ok, {Mut, Org + 1}} end,
    [#sweep_participant{module = observ_callback_module,
                       sweep_fun = ObservFun,
                       fun_type = observe_fun,
                        acc = {0,0}
                       }].

delete_sweep(N) ->
    DeleteFun =
        fun({{_, BKey}, _RObj}, Acc, _Opt) ->
                rem_keys(BKey, N, {deleted, Acc + 1}, {ok, Acc})
        end,
    [#sweep_participant{module = delete_callback_module,
                       sweep_fun = DeleteFun,
                       fun_type = delete_fun,
                        acc = 0
                       }].

make_keys(Nr) ->
    [integer_to_binary(N) || N <- lists:seq(1, Nr)].

meck_callback_modules(Module) ->
    meck:new(Module, [non_strict]),
    meck:expect(Module, failed_sweep, fun(_Index, _Reason) -> ok end),
    meck:expect(Module, successful_sweep, fun(_Index, _Reason) -> ok end).

rem_keys(BKey, N, MatchReturn, DefaultReturn) ->
    case binary_to_integer(BKey) rem N of
        0 ->
            MatchReturn;
        _ ->
            DefaultReturn
    end.

modify_sweep(N) ->
    ModifyFun =
        fun({{_Bucket, BKey}, _RObj}, Acc, _Opt) ->
                rem_keys(BKey, N, {mutated, <<"mutated">>, Acc + 1}, {ok, Acc})
        end,
    [#sweep_participant{module = modify_callback_module,
                        sweep_fun = ModifyFun,
                        fun_type = modify_fun,
                        acc = 0
                       }].

%% delete sweep participant that ask for bucket props
delete_sweep_bucket_props() ->
    %% Check that we receive bucket_props when we ask for it
    DeleteFun = fun({_BKey, _RObj}, Acc, [{bucket_props, _}]) -> {deleted, Acc} end,
    [#sweep_participant{module = delete_callback_module,
                       sweep_fun = DeleteFun,
                       fun_type = delete_fun,
                       options = [bucket_props]}].
%% Crashing delete sweep participant
delete_sweep_crash() ->
    DeleteFun = fun({_BKey, RObj}, _Acc, _Opt) -> RObj = crash end,
    [#sweep_participant{module = delete_callback_module,
                        sweep_fun = DeleteFun,
                        fun_type = delete_fun,
                        options = [bucket_props]}].

%% Basic sweep test. Check that callback get complete Acc when sweep finish
sweep_delete_test() ->
    setup_sweep(Keys = 100),
    DeleteRem = 3,
    {reply, Acc, _State} =
        do_sweep(delete_sweep(DeleteRem), 0, no_sender, [], no_index, fake_backend, [], []),
    ?assertEqual(Keys, Acc#sa.swept_keys),
    %% Verify acc return
    [{_Pid,{_,_,[_,N]},ok}] = meck:history(delete_callback_module),
    ?assertEqual(Keys div DeleteRem, N),
    meck:unload().

%% Verify that a sweep asking for bucket_props gets them
sweep_delete_bucket_props_test() ->
    setup_sweep(Keys = 100),
    {reply, Acc, _State} =
        do_sweep(delete_sweep_bucket_props(), 0, no_sender, [], no_index, fake_backend, [], []),

    ?assertEqual(Keys, dict:size(Acc#sa.bucket_props)),
    ?assertEqual(Keys, Acc#sa.swept_keys),
    meck:unload().

%% Delete 1/3 of the keys the rest gets seen by the observer sweep
sweep_observ_delete_test() ->
    setup_sweep(Keys = 100),
    DeleteRem = 3,
    Sweeps = delete_sweep(DeleteRem) ++ observ_sweep(),
    {reply, Acc, _State} = do_sweep(Sweeps, 0, no_sender, [], no_index, fake_backend, [], []),
    ?assertEqual(Keys, Acc#sa.swept_keys),
    %% Verify acc return
    [{_Pid,{_,_,[_,DeleteN]},ok}] = meck:history(delete_callback_module),
    [{_Pid,{_,_,[_,{0, ObservN}]},ok}] = meck:history(observ_callback_module),

    NrDeleted = Keys div DeleteRem,
    ?assertEqual(NrDeleted, DeleteN),
    ?assertEqual(Keys - NrDeleted, ObservN),
    ?assertEqual(Keys, Acc#sa.swept_keys),
    meck:unload().

%% Test including all types of sweeps. Delete 1/4 Modify 1/4 and
sweep_modify_observ_delete_test() ->
    setup_sweep(Keys = 100),
    DeleteRem = 4,
    ModifyRem = 2,
    Sweeps = delete_sweep(DeleteRem) ++ observ_sweep() ++ modify_sweep(ModifyRem),
    {reply, Acc, _State} = do_sweep(Sweeps, 0, no_sender, [], no_index, fake_backend, [], []),
    %% Verify acc return
    [{_Pid,{_,_,[_,DeleteN]},ok}] = meck:history(delete_callback_module),
    [{_Pid,{_,_,[_,ModifyN]},ok}] = meck:history(modify_callback_module),
    [{_Pid,{_,_,[_,{Mod, Org}]},ok}] = meck:history(observ_callback_module),

    %% Delete and modify should have touched the same number of object.
    NrDeletedModify = Keys div DeleteRem,
    ?assertEqual(NrDeletedModify, DeleteN),
    ?assertEqual(NrDeletedModify, ModifyN),

    ?assertEqual(Mod, ModifyN),
    ?assertEqual(Org, Keys - DeleteN - ModifyN),
    ?assertEqual(Keys, Acc#sa.swept_keys),
    meck:unload().

%% Verify that even if one sweep crashes for all objects the following participants still run
sweep_delete_crash_observ_test() ->
    setup_sweep(Keys = 100),
    Sweeps = delete_sweep_crash() ++ observ_sweep(),
    {reply, Acc, _State} = do_sweep(Sweeps, 0, no_sender, [], no_index, fake_backend, [], []),
    [{_Pid,{_,_,[_,DeleteN]},ok}] = meck:history(delete_callback_module),
    [{_Pid,{_,_,[_,ObservAcc]},ok}] = meck:history(observ_callback_module),

    %% check that the delete sweep failed but observer succeed
    ?assertEqual(too_many_crashes, DeleteN),
    ?assertEqual({0, Keys}, ObservAcc),
    ?assertEqual(Keys, Acc#sa.swept_keys),
    meck:unload().

make_initial_sweep_participant_test() ->
    SP0s = [#sweep_participant{module = 3, fun_type = observe_fun},
            #sweep_participant{module = 2, fun_type = modify_fun},
            #sweep_participant{module = 1, fun_type = delete_fun}],
    #sa{active_p = SPs} = make_initial_acc(1, SP0s, 100),
    [1, 2, 3] = [SP#sweep_participant.module || SP <- SPs],
    ok.

-endif.

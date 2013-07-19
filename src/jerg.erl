%%
%% ___     _        __     _____       ___
%%   (_   | \    ___) |    \    )  ____)  
%%     |  |  |  (__   |     )  /  /  __   
%%  _  |  |  |   __)  |    /  (  (  (  \  
%% ( |_|  |  |  (___  | |\ \   \  \__)  ) 
%% _\    /__/       )_| |_\ \___)      (__
%%
%% jerg - JSON Schema to Erlang Records Generator
%%
%% @author david@dossot.net
%%

-module(jerg).

-export([main/1]).

-define(OPT_SPEC_LIST,
    [
     {source,  $s, "source",  string,                               "Source directory or file."},
     {target,  $t, "target",  {string, "include/json_records.hrl"}, "Generation target. Use - to output to stdout."},
     {prefix,  $p, "prefix",  string,                               "Records name prefix."},
     {version, $v, "version", undefined,                            "Display version information and stop."}
    ]).

-define(RECORD_PREFIX_PROPERTY, '~recordPrefix').

-spec main(string()) -> term().
main(Args) ->
    application:load(jerg),
    
    case getopt:parse(?OPT_SPEC_LIST, Args) of
        {ok, {ParsedOpts, []}} when length(ParsedOpts) > 0 ->
            run(ParsedOpts),
            io:format("==> jerg (generation complete)~n");
        _ ->
            usage_and_bail()
    end.

%% Private functions
-spec usage_and_bail() -> no_return().
usage_and_bail() ->
    getopt:usage(?OPT_SPEC_LIST, "jerg"),
    halt(1).

-spec version_and_bail() -> no_return().
version_and_bail() ->
    io:format("jerg v~s~n~s", [get_jerg_version(), erlang:system_info(system_version)]),
    halt(0).

-spec run(list()) -> ok.
run(ParsedOpts) when is_list(ParsedOpts) ->
    case lists:member(version, ParsedOpts) of
        true ->
            version_and_bail();
        _ ->
            ok
    end,
    
    SourceOpt =
        case_path_has_value(
          [source],
          ParsedOpts,
          fun id/1,
          fun usage_and_bail/0),
    
    Source = filename:absname(SourceOpt),
    ensure_source_exists(Source),
    
    SchemaGraph =
        case_path_has_value(
          [prefix],
          ParsedOpts,
          fun(Prefix) ->
            load_source(Source, Prefix)                  
          end,
          fun() ->
            load_source(Source, undefined)
          end), 
    
    IoDeviceOut = get_output_io_device(ParsedOpts),
    
    % set relationships and ensure no cyclicity
    set_schemas_relationships(SchemaGraph),
    ensure_no_cyclicity(SchemaGraph),
    
    {ok, IoDeviceIn} = file:open(<<>>, [ram,binary,read,write]),
    output_records(SchemaGraph, IoDeviceIn),
    file:position(IoDeviceIn, 0),
    copy_io_devices(IoDeviceIn, IoDeviceOut),
    close_io_device(IoDeviceIn),
    close_io_device(IoDeviceOut),
    ok.

-spec get_output_io_device(list()) -> file:io_device().
get_output_io_device(ParsedOpts) when is_list(ParsedOpts) ->
    case kvc:path([target], ParsedOpts) of
        "-" ->
            group_leader();
        TargetOpt ->
            OutputFile = filename:absname(TargetOpt),
            ok = filelib:ensure_dir(OutputFile),
            {ok, IoDeviceOut} = file:open(OutputFile, [binary, write]),
            io:format("==> jerg (outputting to: ~s)~n", [OutputFile]),
            IoDeviceOut
    end.

-spec load_source(string(), string() | undefined) -> digraph().
load_source(Source, Prefix) ->
    SchemaGraph = digraph:new(),
    case filelib:is_dir(Source) of
        true ->
            {ok, FileNames} = file:list_dir(Source),
            SchemaFiles = [filename:join(Source, FileName) || FileName <- FileNames],
            load_schemas(SchemaFiles, SchemaGraph, Prefix);
        _ ->
            load_single_schema(Source, SchemaGraph, Prefix)
    end,
    SchemaGraph.

-spec load_schemas(list(string()), digraph(), string() | undefined) -> ok.
load_schemas([], _, _) ->
    ok;
load_schemas([SchemaFile|Rest], SchemaGraph, Prefix) ->
    load_single_schema(SchemaFile, SchemaGraph, Prefix),
    load_schemas(Rest, SchemaGraph, Prefix).

-spec load_single_schema(string(), digraph(), string() | undefined) -> digraph:vertex().
load_single_schema(SchemaFile, SchemaGraph, Prefix) ->
    {ok, SchemaFileContent} = file:read_file(SchemaFile),
    JsonSchema = parse_and_enrich_json_schema(SchemaFileContent, Prefix),
    ensure_supported_json_schema(SchemaFile, JsonSchema),
    SchemaBaseFile = filename:basename(SchemaFile),
    SchemaId = list_to_binary(filename:rootname(SchemaBaseFile)),
    digraph:add_vertex(SchemaGraph, list_to_binary(SchemaBaseFile), {SchemaId, JsonSchema}).

-spec parse_and_enrich_json_schema(binary(), string() | undefined) -> jsx:json_term().
parse_and_enrich_json_schema(Json, undefined) ->
    jsx:decode(Json);
parse_and_enrich_json_schema(Json, Prefix) ->
    JsonSchema = jsx:decode(Json),
    [{atom_to_binary(?RECORD_PREFIX_PROPERTY, utf8), list_to_binary(Prefix)} | JsonSchema].

-spec ensure_source_exists(string()) -> ok.
ensure_source_exists(Source) ->
    ensure(fun() -> filelib:is_file(Source) end,
           fun() -> {Source, "is not a file or a directory"} end).

-spec ensure_supported_json_schema(string(), jsx:json_term()) -> ok.
ensure_supported_json_schema(FileName, JsonSchema) when is_list(JsonSchema) ->
    ensure(fun() -> not(case_path_or_default([additionalProperties], JsonSchema, false)) end,
           fun() -> {FileName, "additionalProperties are not supported"} end);
ensure_supported_json_schema(FileName, _) ->
    throw({error, {FileName, "JSON Schema is not an object"}}).

-spec get_schema(digraph(), binary()) -> {binary(), jsx:json_term()}.
get_schema(SchemaGraph, Vertex) ->
    {Vertex, {RawSchemaId, JsonSchema}} = digraph:vertex(SchemaGraph, Vertex),
    {get_schema_id(RawSchemaId, JsonSchema), JsonSchema}.

-spec get_schema_id(binary(), jsx:json_term()) -> binary().
get_schema_id(RawSchemaId, JsonSchema) ->
    ActualSchemaId = case_path_or_default(
      [recordName],
      JsonSchema,
      RawSchemaId),
    
    case_path_has_value(
      [?RECORD_PREFIX_PROPERTY],
      JsonSchema,
      fun(RecordPrefix) ->
        <<RecordPrefix/binary, ActualSchemaId/binary>>
      end,
      fn(ActualSchemaId)).

-spec set_schemas_relationships(digraph()) -> ok.
set_schemas_relationships(SchemaGraph) ->
    set_schemas_relationships(
      SchemaGraph,
      get_schema_vertices(SchemaGraph)).

-spec set_schemas_relationships(digraph(), list(jsx:json_term())) -> ok.
set_schemas_relationships(_, []) ->
    ok;
set_schemas_relationships(SchemaGraph, [Vertex|Vertices]) ->
    {_, JsonSchema} = get_schema(SchemaGraph, Vertex),
    SchemaDependencies = get_schema_dependencies(JsonSchema),
    set_schema_relationships(SchemaGraph, Vertex, SchemaDependencies),
    set_schemas_relationships(SchemaGraph, Vertices).

-spec set_schema_relationships(digraph(), jsx:json_term(), list(jsx:json_term())) -> ok.
set_schema_relationships(_, _, []) ->
    ok;
set_schema_relationships(SchemaGraph, Vertex, [DependencyVertex|SchemaDependencies]) ->
    digraph:add_edge(SchemaGraph, Vertex, DependencyVertex),
    set_schema_relationships(SchemaGraph, Vertex, SchemaDependencies).
    
-spec get_schema_dependencies(jsx:json_term()) -> list(jsx:json_term()).
get_schema_dependencies(JsonSchema) ->
    RawDependencies =
        [get_schema_parent_vertex(JsonSchema) | get_schema_ref_vertices(JsonSchema)],
    
    lists:filter(
      fun(D) ->
              D =/= undefined
      end,
      lists:flatten(RawDependencies)).
    
-spec get_schema_parent_vertex(jsx:json_term()) -> jsx:json_term() | undefined.
get_schema_parent_vertex(JsonSchema) ->
    case_path_or_default([extends,'$ref'], JsonSchema, undefined).

-spec get_schema_ref_vertices(jsx:json_term()) -> list().
get_schema_ref_vertices(JsonSchema) ->
    [[kvc:path(['$ref'], S)] ++ [kvc:path([items,'$ref'], S)] || {_, S} <- kvc:path([properties], JsonSchema)].

-spec ensure_no_cyclicity(digraph()) -> ok.
ensure_no_cyclicity(SchemaGraph) ->
    ensure(fun() -> digraph_utils:is_acyclic(SchemaGraph) end,
           fun() -> {schema_cyclic, digraph_utils:cyclic_strong_components(SchemaGraph)} end).  

-spec output_records(digraph(), file:io_device()) -> ok.
output_records(SchemaGraph, IoDevice) ->
    {{Year,Month,Day},{Hour,Min,Sec}} = erlang:localtime(),
    output("%%~n%% Generated by jerg v~s on ~B-~2..0B-~2..0B at ~2..0B:~2..0B:~2..0B~n%%~n%% DO NOT EDIT - CHANGES WILL BE OVERWRITTEN!~n%%~n~n",
           [get_jerg_version(), Year, Month, Day, Hour, Min, Sec],
           IoDevice),
    output_records(SchemaGraph, get_schema_vertices(SchemaGraph), IoDevice).

-spec get_schema_vertices(digraph()) -> list(digraph:vertex()).
get_schema_vertices(SchemaGraph) ->
    get_schema_vertices(SchemaGraph, digraph:no_edges(SchemaGraph)).

-spec get_schema_vertices(digraph(), non_neg_integer()) -> list(digraph:vertex()).
get_schema_vertices(SchemaGraph, 0) ->
    digraph:vertices(SchemaGraph);
get_schema_vertices(SchemaGraph, _NumberOfEdges) ->
    digraph_utils:postorder(SchemaGraph).

-spec output_records(digraph(), list(digraph:vertex()), file:io_device()) -> ok.
output_records(_, [], _) ->
    ok;
output_records(SchemaGraph, [Vertex|Vertices], IoDevice) when is_list(Vertices) ->
    {SchemaId, JsonSchema} = get_schema(SchemaGraph, Vertex),
    output_record(SchemaGraph, SchemaId, JsonSchema, IoDevice),
    output_records(SchemaGraph, Vertices, IoDevice).

-spec output_record(digraph(), binary(), jsx:json_term(), file:io_device()) -> ok.
output_record(SchemaGraph, SchemaId, JsonSchema, IoDevice) ->
    case {kvc:path([type], JsonSchema), kvc:path([abstract], JsonSchema)} of
        {<<"object">>, Abstract} when Abstract =:= false ; Abstract =:= [] ->
            output_object_record(SchemaGraph, SchemaId, JsonSchema, IoDevice);
        _ ->
            ok
    end.

-spec output_object_record(digraph(), binary(), jsx:json_term(), file:io_device()) -> no_return().
output_object_record(SchemaGraph, SchemaId, JsonSchema, IoDevice) ->
    output_title(JsonSchema, IoDevice),
    output_description(JsonSchema, IoDevice),
    output("-record('~s',~n~s{~n", [SchemaId, string:chars($ , 8)], IoDevice),
    output_properties(SchemaGraph, JsonSchema, IoDevice),
    output("~s}).~n~n", [string:chars($ , 8)], IoDevice).

-spec output_title(jsx:json_term(), file:io_device()) -> ok.
output_title(JsonObject, IoDevice) ->
    output_title(JsonObject, IoDevice, "").

-spec output_title(jsx:json_term(), file:io_device(), string()) -> ok.
output_title(JsonObject, IoDevice, Margin) ->
    output_path_value([title], JsonObject, Margin ++ "% ~s~n", IoDevice).

-spec output_description(jsx:json_term(), file:io_device()) -> ok.
output_description(JsonObject, IoDevice) ->
    output_description(JsonObject, IoDevice, "").

-spec output_description(jsx:json_term(), file:io_device(), string()) -> ok.
output_description(JsonObject, IoDevice, Margin) ->
    output_path_value([description], JsonObject, Margin ++ "% ~s~n", IoDevice).

-spec output_properties(digraph(), jsx:json_term(), file:io_device()) -> no_return().
output_properties(SchemaGraph, JsonSchema, IoDevice) ->
    Properties = collect_properties(SchemaGraph, JsonSchema),
    NameWidth = find_longest_property_name(Properties),
    DefaultValueWidth = find_longest_default_value(SchemaGraph, Properties),
    output_property(SchemaGraph, Properties, IoDevice, NameWidth, DefaultValueWidth).

-spec output_property(digraph(), list(jsx:json_term()), file:io_device(), integer(), integer()) -> ok.
output_property(_, [], _, _, _) ->
    ok;
output_property(SchemaGraph, [{PropertyName, PropertySchema}|Properties], IoDevice, NameWidth, DefaultValueWidth) ->
    Margin = string:chars($ , 12),
    
    output_title(PropertySchema, IoDevice, Margin),
    output_description(PropertySchema, IoDevice, Margin),
    
    DefaultValue = format_default_value(SchemaGraph, PropertySchema, DefaultValueWidth),
    TypeSpec = get_property_type_spec(SchemaGraph, PropertySchema),
    
    output(
      "~s~-" ++ integer_to_list(NameWidth) ++ "s ~s:: ~s",
      [Margin, PropertyName, DefaultValue, TypeSpec],
      IoDevice),
    
    case length(Properties) of
        0 ->
            output("~n", IoDevice);
        _ ->
            output(",~n", IoDevice)
    end,
    output_property(SchemaGraph, Properties, IoDevice, NameWidth, DefaultValueWidth).

-spec format_default_value(digraph(), jsx:json_term(), integer()) -> binary().
format_default_value(_, _, 0) ->
    <<>>;
format_default_value(SchemaGraph, PropertySchema, DefaultValueWidth) ->
    DefaultValue = get_property_default_value(SchemaGraph, PropertySchema),
    format_default_value(DefaultValue, DefaultValueWidth).

-spec format_default_value(binary(), integer()) -> binary().
format_default_value(<<>>, DefaultValueWidth) ->
    binary:copy(<<" ">>, DefaultValueWidth + 3);
format_default_value(DefaultValue, DefaultValueWidth) ->
    format_to_binary("= ~-" ++ integer_to_list(DefaultValueWidth) ++ "s ", [DefaultValue]).

-spec collect_properties(digraph(), jsx:json_term()) -> list(jsx:json_term()).
collect_properties(SchemaGraph, JsonSchema) ->
    Properties = kvc:path([properties], JsonSchema),
    
    case get_schema_parent_vertex(JsonSchema) of
        undefined ->
            Properties;
        ParentVertex ->
            {_, ParentJsonSchema} = get_schema(SchemaGraph, ParentVertex),
            collect_properties(SchemaGraph, ParentJsonSchema) ++ Properties
    end.

-spec find_longest_property_name(jsx:json_term()) -> integer().
find_longest_property_name(Properties) ->
    lists:max([size(PropertyName) || {PropertyName, _} <- Properties]).

-spec find_longest_default_value(digraph(), jsx:json_term()) -> binary().
find_longest_default_value(SchemaGraph, Properties) ->
    lists:max([size(get_property_default_value(SchemaGraph, PropertySchema)) || {_, PropertySchema} <- Properties]).

-spec get_property_default_value(digraph(), jsx:json_term()) -> binary().
get_property_default_value(SchemaGraph, PropertySchema) ->
    case_path_has_value(
      ['default'],
      PropertySchema,
      fun(DefaultValue) ->
          convert_property_default_value(SchemaGraph, PropertySchema, DefaultValue)
      end,
      fn(<<>>)).

-spec convert_property_default_value(digraph(), jsx:json_term(), term()) -> binary().
convert_property_default_value(SchemaGraph, PropertySchema, DefaultValue) ->
    TypeSpec = get_property_type_spec(SchemaGraph, PropertySchema),
    convert_property_value(DefaultValue, TypeSpec).

-spec convert_property_value(digraph(), binary()) -> binary().
convert_property_value(_, <<"term()">>) ->
    <<>>;
convert_property_value(DefaultValue, _) ->
    format_to_binary("~p", [DefaultValue]).

-spec get_property_type_spec(digraph(), jsx:json_term()) -> binary().
get_property_type_spec(SchemaGraph, PropertySchema) ->
    case_path_has_value(
      ['$ref'],
      PropertySchema,
      fun(Ref) ->
          get_schema_reference_type_spec(SchemaGraph, Ref)
      end,
      fun() ->
          convert_property_type_spec(SchemaGraph, kvc:path([type], PropertySchema), PropertySchema)
      end).

-spec get_schema_reference_type_spec(digraph(), binary()) -> binary().
get_schema_reference_type_spec(SchemaGraph, Ref) ->
  {RawSchemaId, JsonSchema} = get_schema(SchemaGraph, Ref),
  SchemaId = get_schema_id(RawSchemaId, JsonSchema),
  <<"#", SchemaId/binary, "{}">>.

-spec get_enum_type_spec(list()) -> binary().
get_enum_type_spec([]) ->
    <<>>;
get_enum_type_spec([Value]) ->
    format_to_binary("~p", [Value]);
get_enum_type_spec([Value|Values]) ->
    <<(format_to_binary("~p", [Value]))/binary,
      " | ",
      (get_enum_type_spec(Values))/binary>>.

-spec convert_property_type_spec(digraph(), jsx:json_term(), jsx:json_term()) -> binary().
convert_property_type_spec(_, [], _) ->
    <<"term()">>; % default type
convert_property_type_spec(SchemaGraph, [UnionedType], PropertySchema) ->
    convert_property_type_spec(SchemaGraph, UnionedType, PropertySchema);
convert_property_type_spec(SchemaGraph, [UnionedType|OtherTypes], PropertySchema) ->
    <<(convert_property_type_spec(SchemaGraph, UnionedType, PropertySchema))/binary,
      " | ",
      (convert_property_type_spec(SchemaGraph, OtherTypes, PropertySchema))/binary>>;
convert_property_type_spec(_, <<"object">>, _) ->
    <<"term()">>;
convert_property_type_spec(SchemaGraph, <<"array">>, PropertySchema) ->
    <<"list(",
      (get_property_type_spec(SchemaGraph, kvc:path([items], PropertySchema)))/binary,
      ")">>;
convert_property_type_spec(_, <<"null">>, _) ->
    <<"null">>;
convert_property_type_spec(_, <<"string">>, _) ->
    <<"binary()">>;
convert_property_type_spec(_, <<"integer">>, PropertySchema) ->
    case_path_has_value(
      [enum],
      PropertySchema,
      fun(Enum) ->
          get_enum_type_spec(Enum)
      end,
      fun() ->
          <<"integer()">>
      end);
convert_property_type_spec(_, Type, _) when is_binary(Type) ->
    <<Type/binary, "()">>.

-spec output_path_value([kvc:kvc_key()], jsx:json_term(), io:format(), file:io_device()) -> ok. 
output_path_value(Path, JsonObject, Format, IoDevice) ->
    case_path_has_value(Path, JsonObject, fun(Value) -> output(Format, [Value], IoDevice) end),
    ok.

-spec has_json_value(jsx:json_term()) -> boolean().
has_json_value([]) ->
    false;
has_json_value(null) ->
    false;
has_json_value(<<>>) ->
    false;
has_json_value(_) ->
    true.

-spec case_path_has_value([kvc:kvc_key()], jsx:json_term(), fun((jsx:json_term()) -> term()), fun(() -> term())) -> term().
case_path_has_value(Path, Json, HasValueFun, HasntValueFun) ->
    Value = kvc:path(Path, Json),
    case has_json_value(Value) of
        true ->
            HasValueFun(Value);
        _ ->
            HasntValueFun()
    end.

-spec case_path_has_value([kvc:kvc_key()], jsx:json_term(), fun((jsx:json_term()) -> term())) -> term().
case_path_has_value(Path, Json, Fun) ->
    case_path_has_value(
      Path,
      Json,
      Fun,
      fn(ok)).

-spec case_path_or_default([kvc:kvc_key()], jsx:json_term(), term()) -> term().
case_path_or_default(Path, Json, Default) ->
    case_path_has_value(
      Path,
      Json,
      fun id/1,
      fn(Default)).

-spec output(io:format(), file:io_device()) -> ok.
output(Format, IoDevice) ->
    output(Format, [], IoDevice).

-spec output(io:format(), [term()], file:io_device()) -> ok.
output(Format, Data, IoDevice) ->
    Bytes = format_to_binary(Format, Data),
    ok = file:write(IoDevice, Bytes).

-spec copy_io_devices(file:io_device(), file:io_device()) -> ok.
copy_io_devices(IoDeviceIn, IoDeviceOut) ->
    copy_io_devices({ok,<<>>}, IoDeviceIn, IoDeviceOut).

-spec copy_io_devices({ok, binary()} | eof | {error, _}, file:io_device(), file:io_device()) -> ok.
copy_io_devices(eof, _, _) ->
    ok;
copy_io_devices({ok, Data}, IoDeviceIn, IoDeviceOut) ->
    io:format(IoDeviceOut, Data, []),
    copy_io_devices(file:read(IoDeviceIn, 1024), IoDeviceIn, IoDeviceOut).

-spec close_io_device(file:io_device()) -> ok.
close_io_device(IoDevice) ->
    StdOut = group_leader(),
    case IoDevice of
        StdOut ->
            ok;
        _ ->
            ok = file:close(IoDevice)
    end.

-spec ensure(fun(() -> boolean()), fun(() -> term())) -> ok | no_return().
ensure(CheckFun, ErrorMessageFun) ->
    case CheckFun() of
        true ->
            ok;
        false ->
            throw({error, ErrorMessageFun()})
    end.    

-spec format_to_binary(io:format(), [term()]) -> binary().
format_to_binary(Format, Data) ->
    list_to_binary(io_lib:format(Format, Data)).

-spec get_jerg_version() -> string().
get_jerg_version() ->
    {ok, Version} = application:get_key(jerg, vsn),
    Version.

-spec id(term()) -> term().
id(T) -> T.

-spec fn(term()) -> fun(() -> term()).
fn(T) -> fun() -> T end.

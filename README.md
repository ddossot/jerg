<pre>
___     _        __     _____       ___
  (_   | \    ___) |    \    )  ____)  
    |  |  |  (__   |     )  /  /  __   
 _  |  |  |   __)  |    /  (  (  (  \  
( |_|  |  |  (___  | |\ \   \  \__)  ) 
_\    /__/       )_| |_\ \___)      (__
</pre>

# jerg - JSON Schema to Erlang Records Generator

## WAT?

`jerg` generates this:

    % Monetary price
    % Intended to be used embedded in other schemas
    -record(price,
            {
                currency_code :: binary(),
                amount        :: number()
            }).
    
    % Product (Short View)
    % Intended to be used in search results
    -record(product_short,
            {
                % Numeric object identity, set to -1 at creation time
                id             = -1 :: integer(),
                name                :: binary(),
                list_price          :: #price{},
                discount_price      :: #price{}
            }).
    
    % Product Category
    -record(product_category,
            {
                % Numeric object identity, set to -1 at creation time
                id   = -1 :: integer(),
                name      :: binary()
            }).
    
    % Product (Full View)
    % Intended to be used when full description is needed
    -record(product_full,
            {
                % Numeric object identity, set to -1 at creation time
                id             = -1 :: integer(),
                name                :: binary(),
                list_price          :: #price{},
                discount_price      :: #price{},
                description         :: binary(),
                categories          :: list(#product_category{})
            }).

out of that:

<TABLE>
<TBODY>
<TR>
 <TH>category.json</TH>
</TR>
<TR>
 <TD>
  <PRE>{
    "title": "Product Category",
    "recordName": "product_category",
    "type": "object",
    "extends" : {
        "$ref": "identified_object.json"
    },
    "properties": {
        "name": {
            "type": "string"
        }
    }
}</PRE>
 </TD>
</TR>
<TR>
 <TH>identified_object.json</TH>
</TR>
<TR>
 <TD>
  <PRE>{
    "title": "Identity field for all objects",
    "description" : "Intended to be extended by identified objects",
    "type": "object",
    "abstract" : "true",
    "properties": {
        "id": {
            "description" : "Numeric object identity, set to -1 at creation time",
            "type": "integer",
            "default" : -1
        }
    }
}</PRE>
 </TD>
</TR>
<TR>
 <TH>price.json</TH>
</TR>
<TR>
 <TD>
  <PRE>{
    "title": "Monetary price",
    "description" : "Intended to be used embedded in other schemas",
    "type": "object",
    "properties": {
        "currency_code": {
            "type": "string"
        },
        "amount": {
            "type": "number"
        }
    }
}</PRE>
 </TD>
</TR>
<TR>
 <TH>product_full.json</TH>
</TR>
<TR>
 <TD>
  <PRE>{
    "title": "Product (Full View)",
    "description" : "Intended to be used when full description is needed",
    "type": "object",
    "extends" : {
        "$ref": "product_short.json"
    },
    "properties": {
        "description": {
            "type": "string"
        },
        "categories": {
            "type" : "array",
            "items" : {
              "$ref": "category.json"
            }
        }
    }
}</PRE>
 </TD>
</TR>
<TR>
 <TH>product_short.json</TH>
</TR>
<TR>
 <TD>
  <PRE>{
    "title": "Product (Short View)",
    "description" : "Intended to be used in search results",
    "type": "object",
    "extends" : {
        "$ref": "identified_object.json"
    },
    "properties": {
        "name": {
            "type": "string"
        },
        "list_price": {
            "$ref": "price.json"
        },
        "discount_price": {
            "$ref": "price.json"
        }
    }
}</PRE>
 </TD>
</TR>
</TBODY>
</TABLE>

## Features

`jerg` supports:

- cross-references for properties and collection items (ie the `$ref` property),
- default values,
- integer enumerations (other types can not be enumerated per limitation of the Erlang type specification).

`jerg` also supports a few extensions to JSON schema:

- `extends`: to allow a schema to extend another one in order to inherit all the properties of its parent (and any ancestors above it),
- `abstract`: to mark schemas that actually do not need to be output as records because they are just used through references and extension,
- `recordName`: to customize the name of the record generated from the concerned schema definition.


## Build

`jerg` is built with [rebar](https://github.com/basho/rebar).

Run:

    rebar get-deps compile
    rebar escriptize skip_deps=true


## Usage

    $ jerg
    Usage: jerg [-s <source>] [-t [<target>]] [-p <prefix>] [-v]
    
      -s, --source   Source directory or file.
      -t, --target   Generation target. Use - to output to stdout. [default: include/json_records.hrl]
      -p, --prefix   Records name prefix.
      -v, --version  Display version information and stop.

`jerg` is intended to be used as part of your build chain in order to produce Erlang records right before compilation starts.

If you use `rebar`, this is done by adding the following to your `rebar.config`:

    {pre_hooks, [{compile, "jerg -s priv/json_schemas"}]}.

This assumes that your JSON schemas are located in `priv/json_schemas` and you're OK with outputting the generated records to `include/json_records.hrl`.


## What next?

- Use [json_rec](https://github.com/justinkirby/json_rec) to serialize and deserialize JSON to and from Erlang records.
- Use [jesse](https://github.com/klarna/jesse) to validate JSON data against JSON schema.

## Limitations

`jerg` doesn't support the following:

- Embedded object definitions: for now all objects must be defined as top level schema files, 
- Hierarchical organization of schema files,
- URL and self references to schema files,
- Cyclic schema dependencies (_to support it, a potential approach would be to introduce an `any()` type in a dependency cycle in order to break it_),
- Additional properties.


#### Copyright 2013 - David Dossot - MIT License
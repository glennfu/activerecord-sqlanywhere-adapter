# frozen_string_literal: true

require "sqlanywhere2"
require "active_record"
require "arel_sqlanywhere"
require "active_record/connection_adapters/abstract_adapter"
require "active_record/connection_adapters/abstract/transaction_extension"
require "active_record/connection_adapters/sqlanywhere/column"
require "active_record/connection_adapters/sqlanywhere/quoting"
require "active_record/connection_adapters/sqlanywhere/schema_creation"
require "active_record/connection_adapters/sqlanywhere/schema_statements"
require "active_record/connection_adapters/sqlanywhere/database_statements"
require "active_record/connection_adapters/sqlanywhere/schema_dumper"
require "active_record/connection_adapters/sqlanywhere/utils"
require "active_record/connection_adapters/sqlanywhere/version"

module ActiveRecord
  module ConnectionHandling
    CREATE_DB_CONFIG = %i(
      collation
      ncollation
      page_size
      jconnect
      checksum
      system_proc_as_definer
      blank_padding
      dba_user
      dba_password
    )
    SQLE_DATABASE_NOT_FOUND = -83

    def sqlanywhere_connection(config)
      if config[:connection_string]
        connection_string = config[:connection_string]
      else
        conn_config = config.dup

        unless conn_config.has_key?(:database)
          raise ArgumentError, "No database name was given. Please add a :database option."
        end

        connection_string  = "ENG=#{(conn_config.delete(:server))};"
        connection_string += "DBN=#{conn_config.delete(:database)};"
        connection_string += "UID=#{conn_config.delete(:username)};"
        connection_string += "PWD=#{conn_config.delete(:password)};"
        connection_string += "LINKS=#{conn_config.delete(:commlinks)};" if config[:commlinks]
        connection_string += "CON=#{conn_config.delete(:connection_name)};" if config[:connection_name]
        connection_string += "CS=#{conn_config.delete(:encoding)};" if config[:encoding]

        # Since we are using default ConnectionPool class
        # and SqlAnywhere uses CPOOL variable for connection
        # we have to delete pool if it is available
        conn_config.delete(:pool)
        conn_config.delete(:adapter)
        conn_config.delete(:blocking_timeout)

        conn_config.except!(*CREATE_DB_CONFIG)

        # Then add all other connection settings
        conn_config.each_pair do |k, v|
          connection_string += "#{k}=#{v};"
        end
      end

      connection = SQLAnywhere2::Connection.new(conn_string: connection_string)
      ConnectionAdapters::SQLAnywhereAdapter.new(connection, logger, connection_string, config)
    rescue SQLAnywhere2::Error => error
      if error.error_number == SQLE_DATABASE_NOT_FOUND
        raise ActiveRecord::NoDatabaseError
      else
        raise
      end
    end
  end

  module ConnectionAdapters
    class SQLAnywhereAdapter < AbstractAdapter
      include SQLAnywhere::Quoting
      include SQLAnywhere::SchemaStatements
      include SQLAnywhere::DatabaseStatements

      attr_reader :connection_string

      ADAPTER_NAME = "SQLAnywhere"

      def arel_visitor
        Arel::Visitors::SQLAnywhere.new(self)
      end

      def initialize(connection, logger, connection_string, config)
        @auto_commit = true
        @connection_string = connection_string
        super(connection, logger, config)
      end

      def supports_migrations?
        true
      end

      def supports_count_distinct?
        true
      end

      def supports_autoincrement?
        true
      end

      def supports_foreign_keys?
        true
      end

      def supports_json?
        false
      end

      def active?
        # The liveness variable is used a low-cost "no-op" to test liveness
        @connection.execute_immediate("SET liveness = 1")

        true
      rescue SQLAnywhere2::Error
        false
      end

      def disconnect!
        super
        @connection.close
      end

      def reconnect!
        super
        disconnect!
        connect
      end
      alias :reset! :reconnect!

      def discard!
        @connection = nil
      end

      def translate_exception(exception, message:, sql:, binds:)
        case error_number(exception)
        when -83 then NoDatabaseError.db_error(message)
        when -194 then InvalidForeignKey.new(message, sql: sql, binds: binds)
        when -195 then NotNullViolation.new(message, sql: sql, binds: binds)
        when -196 then RecordNotUnique.new(message, sql: sql, binds: binds)
        when -306 then Deadlocked.new(message, sql: sql, binds: binds)
        else
          super
        end
      end

      def error_number(exception)
        exception.error_number if exception.respond_to?(:error_number)
      end

      # Adjust the order of offset & limit as SQLA requires
      # TOP & START AT to be at the start of the statement not the end
      def combine_bind_parameters(
        from_clause: [],
        join_clause: [],
        where_clause: [],
        having_clause: [],
        limit: nil,
        offset: nil
      )
        result = []
        result << limit if limit
        # Can't see a better way of doing this, we need to add 1 to the offset value
        # as SQLA uses START AT, see active_record model query_methods.rb bound_attributes method
        result << Attribute.with_cast_value("OFFSET", offset.value.to_i + 1, Type::Value.new) if offset
        result = result + from_clause + join_clause + where_clause + having_clause
        result
      end

      def get_database_version
        Version.new(select_value("SELECT xp_msver('ProductVersion')"))
      end
      alias :sqlanywhere_version :database_version

      def sqlanywhere?
        true
      end

      class << self
        protected

        def initialize_type_map(m)
          register_class_with_limit m, %r(bit)i,               Type::Boolean
          register_class_with_limit m, %r(char)i,              Type::String
          register_class_with_limit m, %r(binary)i,            Type::Binary
          register_class_with_limit m, %r(long varchar)i,      Type::Text
          register_class_with_precision m, %r(date)i,          Type::Date
          register_class_with_precision m, %r(time)i,          Type::Time
          register_class_with_precision m, %r(timestamp)i,     Type::DateTime

          register_class_with_limit m, %r(integer)i,           Type::Integer
          m.register_type %r(tinyint)i,                        Type::UnsignedInteger.new(limit: 1)
          m.register_type %r(smallint)i,                       Type::Integer.new(limit: 2)
          m.register_type %r(smallint)i,                       Type::Integer.new(limit: 2)
          m.register_type %r(bigint)i,                         Type::Integer.new(limit: 8)
          register_class_with_precision m, %r(float)i,         Type::Float.new
          register_class_with_precision m, %r(real)i,          Type::Float.new(limit: 4)
          register_class_with_precision m, %r(double)i,        Type::Float.new(limit: 8)
          m.register_type %r(decimal)i do |sql_type|
            scale     = extract_scale(sql_type)
            precision = extract_precision(sql_type)
            if scale == 0
              Type::DecimalWithoutScale.new(precision: precision)
            else
              Type::Decimal.new(precision: precision, scale: scale)
            end
          end

          m.alias_type %r(long nvarchar)i,        "text"
          m.alias_type %r(text)i,                 "text"
          m.alias_type %r(ntext)i,                "text"
          m.alias_type %r(xml)i,                  "string"
          m.alias_type %r(datetime)i,             "timestamp"
          m.alias_type %r(smalldatetime)i,        "timestamp"
          m.alias_type %r(long binary)i,          "binary"
          m.alias_type %r(var binary)i,           "binary"
          m.alias_type %r(uniqueidentifier)i,     "binary"
          m.alias_type %r(image)i,                "binary"
          m.alias_type %r(nchar)i,                "char"
          m.alias_type %r(nvarchar)i,             "char"
          m.alias_type %r(varchar)i,              "char"
          m.alias_type %r(varbit)i,               "char"
          m.alias_type %r(uniqueidentifierstr)i,  "char"
          m.alias_type %r(numeric)i,              "decimal"
        end
      end

      TYPE_MAP = Type::TypeMap.new.tap { |m| initialize_type_map(m) }

      protected

      def type_map
        TYPE_MAP
      end

      def column_definitions(table_name)
        scope = quoted_scope(table_name)

        sql = <<~SQL.squish
          SELECT
            SYS.SYSCOLUMN.column_name AS name,
            if left("default",1)='''' then
              substring("default", 2, length("default")-2)
            else
              SYS.SYSCOLUMN."default"
            endif AS "default",
            IF SYS.SYSCOLUMN.domain_id IN (7,8,9,11,33,34,35,3,27) THEN
              IF SYS.SYSCOLUMN.domain_id IN (3,27) THEN
                SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ',' || SYS.SYSCOLUMN.scale || ')'
              ELSE
                SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ')'
              ENDIF
            ELSE
              SYS.SYSDOMAIN.domain_name
            ENDIF AS domain,
            IF SYS.SYSCOLUMN.nulls = 'Y' THEN 1 ELSE 0 ENDIF AS nulls,
            SYS.SYSCOLUMN.remarks
          FROM
            SYS.SYSCOLUMN
          JOIN SYS.SYSTABLE ON SYS.SYSCOLUMN.table_id = SYS.SYSTABLE.table_id
          JOIN SYS.SYSDOMAIN ON SYS.SYSCOLUMN.domain_id = SYS.SYSDOMAIN.domain_id
          JOIN SYS.SYSUSER ON SYS.SYSUSER.user_id = SYS.SYSTABLE.creator
          WHERE SYS.SYSTABLE.table_name = #{scope[:name]} AND SYS.SYSUSER.user_name = #{scope[:owner]}
        SQL
        structure = exec_query(sql, "SCHEMA").to_a

        structure.map do |column|
          if String === column["default"]
            # Escape the hexadecimal characters.
            # For example, a column default with a new line might look like 'foo\x0Abar'.
            # After the gsub it will look like 'foo\nbar'.
            column["default"].gsub!(/\\x(\h{2})/) { $1.hex.chr }
          end
          column
        end

        structure
      end

      private

      def connect
        @connection = SQLAnywhere2::Connection.new(conn_string: @connection_string)
        configure_connection
      end

      def configure_connection
        @connection.execute_immediate("SET TEMPORARY OPTION non_keywords = 'LOGIN'")
        @connection.execute_immediate("SET TEMPORARY OPTION timestamp_format = 'YYYY-MM-DD HH:NN:SS'")
        # The liveness variable is used a low-cost "no-op" to test liveness
        @connection.execute_immediate("CREATE VARIABLE liveness INT")
      rescue
      end
    end
  end
end

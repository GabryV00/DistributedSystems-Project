import ast

def string_to_list(input_string):
    try:
        # Safely evaluate the string using ast.literal_eval
        result_list = ast.literal_eval(input_string)
        # Check if the result is a list of lists
        if isinstance(result_list, list) and all(isinstance(item, list) for item in result_list):
            return result_list
        else:
            raise ValueError("Input string is not in the correct format.")
    except (SyntaxError, ValueError) as e:
        print("Error:", e)
        return None

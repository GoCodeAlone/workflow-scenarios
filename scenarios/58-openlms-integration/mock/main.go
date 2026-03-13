// Mock Moodle Web Services API server for scenario 58-openlms-integration.
// Returns canned Moodle JSON responses for user, course, enrollment, and grade APIs.
// Usage: MOCK_PORT=19058 ./mock-openlms
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19058"
	}
	mux := http.NewServeMux()

	// Standard Moodle Web Services endpoint
	mux.HandleFunc("/webservice/rest/server.php", handleWebService)

	addr := ":" + port
	log.Printf("mock Moodle Web Services API listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// handleWebService dispatches based on the wsfunction query/form parameter.
func handleWebService(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()

	wsfunction := r.FormValue("wsfunction")
	if wsfunction == "" {
		wsfunction = r.URL.Query().Get("wsfunction")
	}

	log.Printf("wsfunction=%s method=%s", wsfunction, r.Method)

	switch wsfunction {
	// --- Users ---
	case "core_user_create_users":
		handleUserCreate(w, r)
	case "core_user_get_users":
		handleUserGet(w, r)
	case "core_user_get_users_by_field":
		handleUserGetByField(w, r)
	case "core_user_search_identity":
		handleUserSearch(w, r)
	case "core_user_update_users":
		handleUserUpdate(w, r)
	case "core_user_delete_users":
		handleUserDelete(w, r)

	// --- Courses ---
	case "core_course_create_courses":
		handleCourseCreate(w, r)
	case "core_course_get_courses":
		handleCourseGet(w, r)
	case "core_course_get_courses_by_field":
		handleCourseGetByField(w, r)
	case "core_course_search_courses":
		handleCourseSearch(w, r)
	case "core_course_get_contents":
		handleCourseGetContents(w, r)
	case "core_course_get_categories":
		handleCourseGetCategories(w, r)
	case "core_course_update_courses":
		handleCourseUpdate(w, r)
	case "core_course_delete_courses":
		handleCourseDelete(w, r)

	// --- Enrollments ---
	case "enrol_manual_enrol_users":
		handleEnrolManual(w, r)
	case "core_enrol_get_enrolled_users":
		handleEnrolGetUsers(w, r)
	case "core_enrol_get_users_courses":
		handleEnrolGetUserCourses(w, r)

	// --- Grades ---
	case "core_grades_get_grades":
		handleGradeGetGrades(w, r)
	case "gradereport_user_get_grade_items":
		handleGradeGetGradeItems(w, r)

	default:
		log.Printf("unmatched wsfunction: %s", wsfunction)
		writeJSON(w, http.StatusOK, map[string]any{
			"errorcode": "invalidfunction",
			"message":   "Unknown function: " + wsfunction,
		})
	}
}

// ---- User handlers ----

func handleUserCreate(w http.ResponseWriter, r *http.Request) {
	username := r.FormValue("users[0][username]")
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":       2,
			"username": username,
		},
	})
}

func handleUserGet(w http.ResponseWriter, r *http.Request) {
	key := r.FormValue("criteria[0][key]")
	value := r.FormValue("criteria[0][value]")
	writeJSON(w, http.StatusOK, map[string]any{
		"users": []map[string]any{
			{
				"id":        2,
				"username":  value,
				"firstname": "John",
				"lastname":  "Doe",
				"email":     value + "@example.com",
				"auth":      "manual",
			},
		},
		"totalrecords": 1,
		"warnings":     []any{},
		"_criteria":    key,
	})
}

func handleUserGetByField(w http.ResponseWriter, r *http.Request) {
	value := r.FormValue("values[0]")
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":        2,
			"username":  "jdoe",
			"firstname": "John",
			"lastname":  "Doe",
			"email":     value,
		},
	})
}

func handleUserSearch(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"list": []map[string]any{
			{
				"id":       2,
				"fullname": "John Doe",
				"email":    "jdoe@example.com",
			},
			{
				"id":       3,
				"fullname": "Jane Smith",
				"email":    "jsmith@example.com",
			},
		},
		"maxusersperpage": 100,
	})
}

func handleUserUpdate(w http.ResponseWriter, _ *http.Request) {
	// Moodle returns null on success
	writeJSON(w, http.StatusOK, nil)
}

func handleUserDelete(w http.ResponseWriter, _ *http.Request) {
	// Moodle returns null on success
	writeJSON(w, http.StatusOK, nil)
}

// ---- Course handlers ----

func handleCourseCreate(w http.ResponseWriter, r *http.Request) {
	shortname := r.FormValue("courses[0][shortname]")
	fullname := r.FormValue("courses[0][fullname]")
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":        2,
			"shortname": shortname,
			"fullname":  fullname,
		},
	})
}

func handleCourseGet(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":         2,
			"shortname":  "CS101",
			"fullname":   "Introduction to Computer Science",
			"categoryid": 1,
			"format":     "topics",
			"visible":    1,
			"summary":    "An introductory CS course.",
		},
	})
}

func handleCourseGetByField(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"courses": []map[string]any{
			{
				"id":        2,
				"shortname": "CS101",
				"fullname":  "Introduction to Computer Science",
			},
		},
	})
}

func handleCourseSearch(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"courses": []map[string]any{
			{
				"id":        2,
				"shortname": "CS101",
				"fullname":  "Introduction to Computer Science",
			},
			{
				"id":        3,
				"shortname": "CS201",
				"fullname":  "Data Structures",
			},
		},
		"total": 2,
	})
}

func handleCourseGetContents(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":      1,
			"name":    "General",
			"visible": 1,
			"summary": "Welcome section",
			"modules": []map[string]any{
				{
					"id":       1,
					"name":     "Course Introduction",
					"modname":  "page",
					"visible":  1,
					"modplural": "Pages",
				},
			},
		},
		{
			"id":      2,
			"name":    "Week 1",
			"visible": 1,
			"summary": "First week topics",
			"modules": []map[string]any{
				{
					"id":       2,
					"name":     "Assignment 1",
					"modname":  "assign",
					"visible":  1,
					"modplural": "Assignments",
				},
			},
		},
	})
}

func handleCourseGetCategories(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":          1,
			"name":        "Miscellaneous",
			"parent":      0,
			"coursecount":  5,
			"description": "Default category",
		},
	})
}

func handleCourseUpdate(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, nil)
}

func handleCourseDelete(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, nil)
}

// ---- Enrollment handlers ----

func handleEnrolManual(w http.ResponseWriter, _ *http.Request) {
	// Moodle returns null on success for manual enrolment
	writeJSON(w, http.StatusOK, nil)
}

func handleEnrolGetUsers(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":        2,
			"username":  "jdoe",
			"firstname": "John",
			"lastname":  "Doe",
			"email":     "jdoe@example.com",
			"roles": []map[string]any{
				{"roleid": 5, "name": "", "shortname": "student"},
			},
		},
		{
			"id":        3,
			"username":  "jsmith",
			"firstname": "Jane",
			"lastname":  "Smith",
			"email":     "jsmith@example.com",
			"roles": []map[string]any{
				{"roleid": 3, "name": "", "shortname": "editingteacher"},
			},
		},
	})
}

func handleEnrolGetUserCourses(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":        2,
			"shortname": "CS101",
			"fullname":  "Introduction to Computer Science",
		},
	})
}

// ---- Grade handlers ----

func handleGradeGetGrades(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"items": []map[string]any{
			{
				"activityid": "1",
				"itemnumber": 0,
				"scaleid":    nil,
				"name":       "Assignment 1",
				"grademin":   0,
				"grademax":   100,
				"grades": []map[string]any{
					{
						"userid": 2,
						"grade":  "85.50",
						"str_grade": "85.50",
					},
				},
			},
		},
		"outcomes": []any{},
	})
}

func handleGradeGetGradeItems(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"usergrades": []map[string]any{
			{
				"courseid":   2,
				"userid":     2,
				"userfullname": "John Doe",
				"maxdepth":   3,
				"gradeitems": []map[string]any{
					{
						"id":           1,
						"itemname":     "Assignment 1",
						"itemtype":     "mod",
						"itemmodule":   "assign",
						"graderaw":     85.5,
						"gradeformatted": "85.50",
						"grademin":     0,
						"grademax":     100,
						"percentageformatted": "85.50 %",
					},
					{
						"id":           2,
						"itemname":     "Quiz 1",
						"itemtype":     "mod",
						"itemmodule":   "quiz",
						"graderaw":     92.0,
						"gradeformatted": "92.00",
						"grademin":     0,
						"grademax":     100,
						"percentageformatted": "92.00 %",
					},
				},
			},
		},
		"warnings": []any{},
	})
}
